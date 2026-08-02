import AVFoundation
import Accelerate
import AppKit
import Observation
import os

// MARK: - Butterchurn Audio Frame

/// Snapshot of audio data for Butterchurn visualization
/// Produced by VisualizerPipeline tap, consumed by ButterchurnBridge at 30 FPS
/// Sendable for safe cross-actor transfer in Swift 6
struct ButterchurnFrame: Sendable {
    let spectrum: [Float]       // 1024 frequency bins (from 2048-point FFT)
    let waveform: [Float]       // 1024 mono samples (time-domain)
    let timestamp: TimeInterval // CACurrentMediaTime() when captured
}

// MARK: - Visualizer Data

/// Container for all visualizer datasets produced by the audio tap
/// Sendable for safe cross-actor transfer in Swift 6
struct VisualizerData: Sendable {
    let rms: [Float]
    /// Consecutive analyzer frames, `spectrumFrameCount` of them laid end to
    /// end, oldest first. A tap delivers 100 ms at a time, so one frame per
    /// delivery would show a tenth of what the audio does; the analyzer instead
    /// gets a frame per hop and plays the batch back over the delivery it
    /// covers.
    let spectrum: [Float]
    let spectrumFrameCount: Int
    /// Audio seconds between consecutive analyzer frames.
    let spectrumHopDuration: TimeInterval
    let waveform: [Float]
    let butterchurnSpectrum: [Float]
    let butterchurnWaveform: [Float]
}

// MARK: - VisualizerPipeline

/// Manages audio visualization tap and data processing.
/// Extracted from AudioPlayer for single responsibility and cleaner separation.
///
/// **Layer:** Mechanism (audio processing)
/// **Responsibilities:**
/// - Owns tap lifecycle and scratch buffer management
/// - Provides callbacks for visualizer data updates
/// - Handles all FFT/spectrum processing on audio thread
/// - Manages Butterchurn frame generation at 30 FPS
@MainActor
@Observable
final class VisualizerPipeline {
    // MARK: - Tap State

    @ObservationIgnored private var tapInstalled = false
    @ObservationIgnored private weak var mixerNode: AVAudioMixerNode?
    @ObservationIgnored private let feed = VisualizerFeed()
    @ObservationIgnored private var pollTimer: Timer?

    /// Optional main-thread hook invoked on every 30 Hz poll tick (engine or video).
    /// `AudioPlayer` uses it to poll each registered video-tap Context's sample rate
    /// for the EQ fanout — keeps `VisualizerPipeline` decoupled from
    /// `EqualizerController`. Fires regardless of whether new visualizer data arrived.
    @ObservationIgnored var onPollTick: (@MainActor () -> Void)?

    /// The shared visualizer feed. Exposed so the video-tap producer
    /// (`videoTapVisualizerRender`) can publish to the SAME single-slot feed the
    /// engine producer uses — only one producer is active at a time (engine for
    /// audio, video tap for video), so the single-slot last-write-wins hand-off is
    /// correct without coordination.
    var sharedFeed: VisualizerFeed { feed }

    // MARK: - Visualizer Data Storage

    /// Analyzer frames stamped with the playback position they describe, filled
    /// by the decoder ahead of the playhead. Preferred over the tap batch below,
    /// which can only describe audio the engine has already rendered.
    @ObservationIgnored let analyzerFeed = SpectrumBandFeed()

    @ObservationIgnored private var latestRMS: [Float] = []
    @ObservationIgnored private var latestWaveform: [Float] = []

    // Analyzer batch awaiting playout: the frames themselves, when they were
    // handed over, and how much audio each one advances.
    @ObservationIgnored private var spectrumBatch: [Float] = []
    @ObservationIgnored private var spectrumFrameCount = 0
    @ObservationIgnored private var spectrumHopDuration: TimeInterval = 0
    @ObservationIgnored private var spectrumBatchArrival: CFTimeInterval = 0

    // Butterchurn audio data - populated by tap, consumed at 30 FPS
    @ObservationIgnored private var butterchurnSpectrum: [Float] = Array(repeating: 0, count: 1024)
    @ObservationIgnored private var butterchurnWaveform: [Float] = Array(repeating: 0, count: 1024)
    @ObservationIgnored private var lastButterchurnUpdate: TimeInterval = 0

    // MARK: - Configuration

    /// Cached spectrum/RMS mode to avoid per-frame AppSettings lookup
    /// AudioPlayer sets this when visualizerMode changes in AppSettings
    var useSpectrum: Bool = true

    // MARK: - Observable State (for UI)

    /// Latest levels for the active mode: 75 analyzer bands, or 20 RMS bars.
    private(set) var levels: [Float] = []

    // MARK: - Initialization

    init() {}

    isolated deinit {
        // Belt-and-suspenders: today the lifecycle is owned by AudioEngineController,
        // which calls removeTap() (and thereby stopPollTimer()) on shutdown. This
        // guards future lifecycle refactors that might drop the last reference
        // without going through removeTap().
        pollTimer?.invalidate()
    }

    // MARK: - Tap Management

    /// Install visualizer tap on the given mixer node
    /// - Parameter mixer: The AVAudioMixerNode to tap
    func installTap(on mixer: AVAudioMixerNode) {
        guard !tapInstalled else { return }

        // Store weak reference for removal
        mixerNode = mixer

        // Remove any existing tap first
        mixer.removeTap(onBus: 0)

        let scratch = VisualizerScratchBuffers()
        let handler = Self.makeTapHandler(feed: feed, scratch: scratch)

        // A tap buffer is clamped to a documented [100, 400] ms range, so this
        // asks for the shortest one available: 4410 frames at 44.1 kHz, one
        // callback per 100 ms. Anything smaller is silently rounded up to the
        // same thing. Both transforms window the rolling history rather than
        // this buffer, so the size sets only the delivery rate.
        let sampleRate = mixer.outputFormat(forBus: 0).sampleRate
        let tapFrames = AVAudioFrameCount((sampleRate / 10).rounded())
        mixer.installTap(onBus: 0, bufferSize: tapFrames, format: nil, block: handler)
        tapInstalled = true
        startPollTimer()

        AppLog.debug(.audio, "VisualizerPipeline: Tap installed")
    }

    /// Remove visualizer tap if installed
    func removeTap() {
        guard tapInstalled else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        if let mixer = mixerNode {
            mixer.removeTap(onBus: 0)
        }
        tapInstalled = false
        mixerNode = nil

        AppLog.debug(.audio, "VisualizerPipeline: Tap removed")
    }

    /// Clear cached visualizer data so UI shows empty bars instead of stale data.
    /// Call after removeTap() when transitioning away from audio playback.
    func clearData() {
        levels = []
        latestRMS = []
        latestWaveform = []
        spectrumBatch = []
        spectrumFrameCount = 0
        butterchurnSpectrum = Array(repeating: 0, count: 1024)
        butterchurnWaveform = Array(repeating: 0, count: 1024)
    }

    /// Check if tap is currently installed
    var isTapInstalled: Bool {
        tapInstalled
    }

    // MARK: - Video Visualization (video-tap producer)

    /// Whether the 30 Hz feed poll timer is currently scheduled (engine OR video).
    var isPollTimerActive: Bool { pollTimer != nil }

    /// Start consuming the shared feed for VIDEO playback. During video the engine
    /// mixer tap is NOT installed (audio flows through AVPlayer, not the engine), so
    /// the 30 Hz poll timer that drives `feed.consume()` must be started independently.
    /// The producer is `videoTapVisualizerRender` (the `MTAudioProcessingTap` render
    /// path), which publishes to the same shared `feed`.
    func startVideoVisualization() {
        startPollTimer()
        AppLog.debug(.audio, "VisualizerPipeline: video visualization started")
    }

    /// Stop video-driven consumption and clear stale bars. Call on video→audio
    /// switch or when video playback stops.
    func stopVideoVisualization() {
        pollTimer?.invalidate()
        pollTimer = nil
        clearData()
        AppLog.debug(.audio, "VisualizerPipeline: video visualization stopped")
    }

    // MARK: - Poll Timer

    /// Poll period for draining the shared feed, one tick per refresh of the
    /// fastest attached display. Polling slower than that would cap how often
    /// the visualizers can see new data, whatever rate they draw at.
    private static var pollInterval: TimeInterval {
        let fastest = NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60
        return 1.0 / Double(max(30, fastest))
    }

    private func startPollTimer() {
        pollTimer?.invalidate()
        // Add to .common run-loop mode so polling continues during user
        // gestures. Timer.scheduledTimer defaults to .default mode, which
        // pauses while the main run loop is in .eventTracking (active
        // DragGesture). That stalled the data pipeline and made the
        // visualizer appear frozen during slider interaction even though
        // VisualizerView's own .common-mode display timer kept firing.
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            dispatchPrecondition(condition: .onQueue(.main))
            MainActor.assumeIsolated {
                self?.pollVisualizerData()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func pollVisualizerData() {
        onPollTick?()  // fire regardless of data availability (sample-rate poll)
        guard let data = feed.consume() else { return }
        updateLevels(with: data, useSpectrum: useSpectrum)
    }

    // MARK: - Butterchurn Data Access

    /// Thread-safe snapshot of current Butterchurn audio data
    /// Called by ButterchurnBridge at 30 FPS to push data to JavaScript
    func snapshotButterchurnFrame() -> ButterchurnFrame {
        ButterchurnFrame(
            spectrum: butterchurnSpectrum,
            waveform: butterchurnWaveform,
            timestamp: lastButterchurnUpdate
        )
    }

    /// Nearest-neighbor resample: map `source` into an array of `targetCount` elements.
    private func resample(_ source: [Float], to targetCount: Int) -> [Float] {
        guard targetCount > 0 else { return [] }
        if source.count == targetCount { return source }
        guard !source.isEmpty else { return [Float](repeating: 0, count: targetCount) }
        var result = [Float](repeating: 0, count: targetCount)
        for i in 0..<targetCount {
            let sourceIndex = (i * source.count) / targetCount
            result[i] = source[min(sourceIndex, source.count - 1)]
        }
        return result
    }

    /// Get RMS data mapped to requested number of bands
    func getRMSData(bands: Int) -> [Float] {
        resample(latestRMS, to: bands)
    }

    /// Get waveform samples resampled to requested count
    func getWaveformSamples(count: Int) -> [Float] {
        resample(latestWaveform, to: count)
    }

    /// Spectrum analyzer band levels for this instant.
    ///
    /// File playback answers from `analyzerFeed`, which the decoder fills ahead
    /// of the playhead, so the bars line up with what is audible. Sources that
    /// never pass through the decoder — streams and video — fall back to the
    /// tap, which hands over 100 ms of already-rendered audio at a time; that
    /// batch is played back over the span it describes, leaving those sources
    /// up to one delivery behind.
    ///
    /// - Parameters:
    ///   - isPlaying: Whether audio is currently rendering; when false the bands
    ///     read zero rather than holding their last values.
    ///   - playbackTime: Seconds into the current file, used to pick the frame
    ///     describing the audible instant.
    /// - Returns: 75 band levels on a 0...255 scale, low frequencies first.
    func spectrumBands(isPlaying: Bool, playbackTime: Double) -> [Float] {
        let width = VisualizerScratchBuffers.spectrumBandCount
        guard isPlaying else {
            return [Float](repeating: 0, count: width)
        }

        if let frame = analyzerFeed.frame(at: playbackTime) {
            return frame
        }

        guard spectrumFrameCount > 0, spectrumHopDuration > 0 else {
            return [Float](repeating: 0, count: width)
        }

        let elapsed = CACurrentMediaTime() - spectrumBatchArrival
        let index = min(spectrumFrameCount - 1, max(0, Int(elapsed / spectrumHopDuration)))
        let frame = spectrumFrame(at: index)
        return frame.isEmpty ? [Float](repeating: 0, count: width) : frame
    }

    // MARK: - Data Update (called from poll timer)

    /// Update visualizer levels with new data from shared buffer
    /// Called on MainActor from 30 Hz poll timer
    func updateLevels(with data: VisualizerData, useSpectrum: Bool) {
        // Store all visualizer datasets
        latestRMS = data.rms
        latestWaveform = data.waveform

        spectrumBatch = data.spectrum
        spectrumFrameCount = data.spectrumFrameCount
        spectrumHopDuration = data.spectrumHopDuration
        spectrumBatchArrival = CACurrentMediaTime()

        // Store Butterchurn data
        butterchurnSpectrum = data.butterchurnSpectrum
        butterchurnWaveform = data.butterchurnWaveform
        lastButterchurnUpdate = CACurrentMediaTime()

        // No smoothing: the analyzer's own fall model is what damps the bars,
        // and a second filter here would flatten the transients it feeds on.
        levels = useSpectrum ? spectrumFrame(at: spectrumFrameCount - 1) : data.rms
    }

    /// Frame `index` of the pending batch, or an empty array when out of range.
    private func spectrumFrame(at index: Int) -> [Float] {
        let width = VisualizerScratchBuffers.spectrumBandCount
        guard index >= 0, index < spectrumFrameCount, (index + 1) * width <= spectrumBatch.count else {
            return []
        }
        return Array(spectrumBatch[(index * width)..<((index + 1) * width)])
    }

    // MARK: - Tap Handler (nonisolated)

    // swiftlint:disable function_body_length
    /// Build the tap handler in a nonisolated context so AVAudioEngine can call it on its realtime queue.
    /// Uses SPSC shared buffer instead of Task { @MainActor } to avoid allocations on the audio thread.
    private nonisolated static func makeTapHandler(
        feed: VisualizerFeed,
        scratch: VisualizerScratchBuffers
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime?) -> Void {
        // swiftlint:disable:next closure_body_length
        { buffer, _ in
            let channelCount = Int(buffer.format.channelCount)
            guard channelCount > 0, let ptr = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            if frameCount == 0 { return }

            let bars = 20
            let cappedFrameCount = scratch.prepare(frameCount: frameCount)

            // Mix channels to mono
            scratch.withMono { mono in
                let invCount = 1.0 / Float(channelCount)
                for frame in 0..<cappedFrameCount {
                    var sum: Float = 0
                    for channel in 0..<channelCount {
                        sum += ptr[channel][frame]
                    }
                    mono[frame] = sum * invCount
                }
            }

            scratch.appendHistory(count: cappedFrameCount)

            // Compute RMS per bar
            scratch.withMonoReadOnly { mono in // swiftlint:disable:this closure_body_length
                scratch.withRms { rms in
                    let bucketSize = max(1, cappedFrameCount / bars)
                    var cursor = 0
                    for b in 0..<bars {
                        let start = cursor
                        let end = min(cappedFrameCount, start + bucketSize)
                        if end > start {
                            var sumSq: Float = 0
                            var index = start
                            while index < end {
                                let sample = mono[index]
                                sumSq += sample * sample
                                index += 1
                            }
                            var value = sqrt(sumSq / Float(end - start))
                            value = min(1.0, value * 4.0)
                            rms[b] = value
                        } else {
                            rms[b] = 0
                        }
                        cursor = end
                    }
                }

            }

            scratch.updateSpectrum(newSamples: cappedFrameCount)

            // Process Butterchurn FFT (2048-point for 1024 bins)
            if scratch.takeButterchurnRefresh() {
                scratch.processButterchurnFFT()
            }

            // Publish to feed (non-blocking: drops frame on contention)
            let hopDuration = Double(VisualizerScratchBuffers.analyzerHop) / buffer.format.sampleRate
            _ = feed.tryPublish(from: scratch, oscilloscopeSamples: 76, hopDuration: hopDuration)
        }
    }
    // swiftlint:enable function_body_length
}
