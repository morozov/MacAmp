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

// MARK: - Shared Buffer (Lock-Free Audio-to-Main Transfer)

/// Thread-safe shared buffer for transferring visualizer data from the audio tap
/// to the main thread without any allocation on the audio thread.
///
/// Uses os_unfair_lock with trylock on the audio thread (non-blocking, drops frame
/// on contention) and regular lock on the main thread (safe to block briefly).
private final class VisualizerSharedBuffer: @unchecked Sendable {
    private var rms = [Float](repeating: 0, count: 20)
    private var spectrum = [Float](
        repeating: 0,
        count: VisualizerScratchBuffers.maxSpectrumFrames * VisualizerScratchBuffers.spectrumBandCount
    )
    private var spectrumFrames = 0
    private var spectrumHopDuration: TimeInterval = 0
    private var waveform = [Float](repeating: 0, count: 76)
    private var bcSpectrum = [Float](repeating: 0, count: 1024)
    private var bcWaveform = [Float](repeating: 0, count: 1024)
    private var waveformCount: Int = 0
    private var rmsCount: Int = 0
    private var spectrumCount: Int = 0

    private var lock = os_unfair_lock()
    private var generation: UInt64 = 0
    private var lastConsumed: UInt64 = 0

    /// Copy Float elements via memcpy. Audio-thread safe (no allocation).
    private func copyFloatBuffer(from source: [Float], to destination: inout [Float], count: Int? = nil) {
        let limit = min(source.count, destination.count)
        let n = min(count ?? limit, limit)
        guard n > 0 else { return }
        source.withUnsafeBufferPointer { src in
            destination.withUnsafeMutableBufferPointer { dst in
                guard let s = src.baseAddress, let d = dst.baseAddress else { return }
                memcpy(d, s, n * MemoryLayout<Float>.stride)
            }
        }
    }

    /// Audio thread: try to publish data (non-blocking).
    /// Returns false if lock is contended (frame is dropped).
    func tryPublish(from scratch: VisualizerScratchBuffers, oscilloscopeSamples: Int, hopDuration: TimeInterval) -> Bool {
        guard os_unfair_lock_trylock(&lock) else { return false }
        defer { os_unfair_lock_unlock(&lock) }

        let rCount = min(scratch.rms.count, rms.count)
        copyFloatBuffer(from: scratch.rms, to: &rms, count: rCount)
        rmsCount = rCount

        spectrumFrames = min(scratch.spectrumFrameCount, VisualizerScratchBuffers.maxSpectrumFrames)
        spectrumHopDuration = hopDuration
        let sCount = min(spectrumFrames * VisualizerScratchBuffers.spectrumBandCount, spectrum.count)
        copyFloatBuffer(from: scratch.spectrum, to: &spectrum, count: sCount)
        spectrumCount = sCount

        // Downsample the whole history, so the oscilloscope's time window stays
        // fixed instead of tracking the tap's buffer size.
        let scratchMono = scratch.history
        let monoLen = scratchMono.count
        let step = max(1, monoLen / oscilloscopeSamples)
        let actualSamples = min(oscilloscopeSamples, waveform.count)
        scratchMono.withUnsafeBufferPointer { src in
            waveform.withUnsafeMutableBufferPointer { dst in
                guard let s = src.baseAddress, let d = dst.baseAddress else { return }
                for i in 0..<actualSamples {
                    let idx = min(i * step, monoLen - 1)
                    d[i] = s[idx]
                }
            }
        }
        waveformCount = actualSamples

        copyFloatBuffer(from: scratch.butterchurnSpectrum, to: &bcSpectrum)
        copyFloatBuffer(from: scratch.butterchurnWaveform, to: &bcWaveform)

        generation &+= 1
        return true
    }

    /// Main thread: consume latest data (blocking lock, safe for main thread).
    func consume() -> VisualizerData? {
        os_unfair_lock_lock(&lock)

        guard generation != lastConsumed else {
            os_unfair_lock_unlock(&lock)
            return nil
        }
        lastConsumed = generation

        // Copy raw data under lock (memcpy only, no construction)
        let localRms = Array(rms.prefix(rmsCount))
        let localSpec = Array(spectrum.prefix(spectrumCount))
        let localFrames = spectrumFrames
        let localHop = spectrumHopDuration
        let localWave = Array(waveform.prefix(waveformCount))
        let localBcSpec = Array(bcSpectrum)
        let localBcWave = Array(bcWaveform)

        os_unfair_lock_unlock(&lock)

        // Construct VisualizerData after releasing lock
        return VisualizerData(
            rms: localRms,
            spectrum: localSpec,
            spectrumFrameCount: localFrames,
            spectrumHopDuration: localHop,
            waveform: localWave,
            butterchurnSpectrum: localBcSpec,
            butterchurnWaveform: localBcWave
        )
    }
}

// MARK: - Scratch Buffers

/// Scratch buffers are confined to the audio tap queue, so @unchecked Sendable is safe.
private final class VisualizerScratchBuffers: @unchecked Sendable {
    private(set) var mono: [Float] = []
    private(set) var rms: [Float] = []
    private(set) var spectrum: [Float] = []

    // Newest mono samples, oldest first. Every transform below reads a window
    // out of here rather than out of the callback, so a delivery's size decides
    // only how much new audio arrived, never the shape of a window. It holds a
    // full delivery plus the extra leading samples the oldest window of that
    // delivery needs.
    private(set) var history: [Float] = Array(repeating: 0, count: maxFrameCount + analyzerFFTSize)
    private var butterchurnPending = 0

    // Spectrum analyzer: a 512-point transform stepped every 256 samples, each
    // folded into 75 bands.
    static let spectrumBandCount = 75
    static let analyzerHop = 256
    private static let analyzerFFTSize = 512
    private static let analyzerBins = analyzerFFTSize / 2
    /// Frames one delivery can produce, at the smallest hop over the largest
    /// delivery.
    static let maxSpectrumFrames = maxFrameCount / analyzerHop + 1

    private(set) var spectrumFrameCount = 0

    private var analyzerWindow: [Float] = Array(repeating: 0, count: analyzerFFTSize)
    private var analyzerWindowed: [Float] = Array(repeating: 0, count: analyzerFFTSize)
    private var analyzerInputReal: [Float] = Array(repeating: 0, count: analyzerBins)
    private var analyzerInputImag: [Float] = Array(repeating: 0, count: analyzerBins)
    private var analyzerOutputReal: [Float] = Array(repeating: 0, count: analyzerBins)
    private var analyzerOutputImag: [Float] = Array(repeating: 0, count: analyzerBins)
    private var analyzerMagnitudes: [Float] = Array(repeating: 0, count: analyzerBins)
    private let analyzerSetup: vDSP_DFT_Setup?

    // Butterchurn FFT buffers
    private static let butterchurnFFTSize: Int = 2048
    private static let butterchurnBins: Int = 1024

    private var butterchurnReal: [Float] = Array(repeating: 0, count: butterchurnFFTSize)
    private var butterchurnImag: [Float] = Array(repeating: 0, count: butterchurnFFTSize)
    private(set) var butterchurnSpectrum: [Float] = Array(repeating: 0, count: butterchurnBins)
    private(set) var butterchurnWaveform: [Float] = Array(repeating: 0, count: butterchurnBins)

    // Pre-allocated FFT working buffers (avoid per-buffer allocations on audio thread)
    private var hannWindow: [Float] = Array(repeating: 0, count: butterchurnFFTSize)
    private var fftInputReal: [Float] = Array(repeating: 0, count: butterchurnFFTSize / 2)
    private var fftInputImag: [Float] = Array(repeating: 0, count: butterchurnFFTSize / 2)
    private var fftOutputReal: [Float] = Array(repeating: 0, count: butterchurnFFTSize / 2)
    private var fftOutputImag: [Float] = Array(repeating: 0, count: butterchurnFFTSize / 2)

    // vDSP FFT setup (log2(2048) = 11)
    private let fftSetup: vDSP_DFT_Setup?

    // Pre-allocated capacity to avoid reallocation on frame-size changes. A tap
    // delivers at least 100 ms per callback, which is 4410 frames at 44.1 kHz
    // and 4800 at 48 kHz; anything shorter than the delivery would drop the
    // tail of every buffer and leave gaps in the history.
    private static let maxFrameCount = 8192
    private static let maxBars = 20

    init() {
        // Create FFT setup for 2048-point real-to-complex transform
        fftSetup = vDSP_DFT_zrop_CreateSetup(
            nil,
            vDSP_Length(Self.butterchurnFFTSize),
            .FORWARD
        )

        analyzerSetup = vDSP_DFT_zrop_CreateSetup(
            nil,
            vDSP_Length(Self.analyzerFFTSize),
            .FORWARD
        )

        // Pre-compute Hann window (never changes)
        vDSP_hann_window(&hannWindow, vDSP_Length(Self.butterchurnFFTSize), Int32(vDSP_HANN_NORM))

        // Periodic Hann, peak 1.0: the analyzer's band scale is calibrated to a
        // window of unit amplitude, so this one is built rather than taken from
        // vDSP_hann_window's normalized variant.
        for n in 0..<Self.analyzerFFTSize {
            analyzerWindow[n] = 0.5 * (1 - cos(2 * Float.pi * Float(n) / Float(Self.analyzerFFTSize)))
        }

        // Pre-allocate buffers at max capacity to avoid reallocation
        mono = Array(repeating: 0, count: Self.maxFrameCount)
        rms = Array(repeating: 0, count: Self.maxBars)
        spectrum = Array(repeating: 0, count: Self.maxSpectrumFrames * Self.spectrumBandCount)
    }

    deinit {
        if let setup = fftSetup {
            vDSP_DFT_DestroySetup(setup)
        }
        if let setup = analyzerSetup {
            vDSP_DFT_DestroySetup(setup)
        }
    }

    func prepare(frameCount: Int) -> Int {
        // CRITICAL: Never allocate on audio thread. Clamp to pre-allocated capacity
        // instead of growing buffers. AVAudioEngine buffer size is 2048, well within
        // our 4096 cap, so this clamp should never activate in normal operation.
        let cappedFrameCount = min(frameCount, mono.count)

        mono.withUnsafeMutableBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            vDSP_vclr(baseAddress, 1, vDSP_Length(cappedFrameCount))
        }

        return cappedFrameCount
    }

    func withMono<R>(_ body: (inout [Float]) -> R) -> R {
        body(&mono)
    }

    func withMonoReadOnly<R>(_ body: ([Float]) -> R) -> R {
        body(mono)
    }

    func withRms<R>(_ body: (inout [Float]) -> R) -> R {
        body(&rms)
    }

    func withSpectrum<R>(_ body: (inout [Float]) -> R) -> R {
        body(&spectrum)
    }

    // MARK: - Sample History

    /// Append the first `count` mono samples to the rolling history, evicting
    /// the oldest.
    func appendHistory(count: Int) {
        let size = history.count
        let n = min(count, mono.count)
        guard n > 0 else { return }

        butterchurnPending += n

        if n >= size {
            let start = n - size
            for i in 0..<size {
                history[i] = mono[start + i]
            }
            return
        }

        let keep = size - n
        for i in 0..<keep {
            history[i] = history[i + n]
        }
        for i in 0..<n {
            history[keep + i] = mono[i]
        }
    }

    /// Whether a full Butterchurn window of samples has arrived since this last
    /// returned true, resetting the count when it does.
    ///
    /// Its transform costs four times the analyzer's and feeds a consumer that
    /// reads one frame per window at most, so it stays on the window's own
    /// cadence rather than the tap's.
    func takeButterchurnRefresh() -> Bool {
        guard butterchurnPending >= Self.butterchurnFFTSize else { return false }
        butterchurnPending = 0
        return true
    }

    // MARK: - Spectrum Analyzer

    /// Recompute `spectrum` as one frame per hop across the newest `newSamples`
    /// samples of history, oldest frame first.
    ///
    /// Each frame is 75 band levels on a 0...255 byte scale, exponentially
    /// spaced at twelve bands per octave. Bands below the first FFT bin's width
    /// share interpolated values; bands wider than one bin total the bins they
    /// cover, so a level is proportional to the energy in the band, not to its
    /// average.
    func updateSpectrum(newSamples: Int) {
        let hop = Self.analyzerHop
        let frames = min(Self.maxSpectrumFrames, max(1, (newSamples + hop - 1) / hop))
        spectrumFrameCount = frames

        for frame in 0..<frames {
            // Frame 0 is the oldest; the last one ends on the newest sample.
            let end = history.count - (frames - 1 - frame) * hop
            analyzeWindow(endingAt: end, into: frame * Self.spectrumBandCount)
        }
    }

    private func analyzeWindow(endingAt end: Int, into destination: Int) {
        guard let setup = analyzerSetup else { return }

        let size = Self.analyzerFFTSize
        let offset = max(0, end - size)

        // The tap averages the channels; this analyzer's input is their sum.
        for i in 0..<size {
            analyzerWindowed[i] = history[offset + i] * 2
        }
        vDSP_vmul(analyzerWindowed, 1, analyzerWindow, 1, &analyzerWindowed, 1, vDSP_Length(size))

        for i in 0..<Self.analyzerBins {
            analyzerInputReal[i] = analyzerWindowed[i * 2]
            analyzerInputImag[i] = analyzerWindowed[i * 2 + 1]
        }
        vDSP_DFT_Execute(setup, analyzerInputReal, analyzerInputImag, &analyzerOutputReal, &analyzerOutputImag)

        // Half of this scale is the analyzer's own; the other half undoes vDSP's
        // convention of returning twice the unnormalized transform for a
        // real-to-complex pass.
        let magnitudeScale: Float = 0.25
        for i in 0..<Self.analyzerBins {
            let real = analyzerOutputReal[i]
            let imag = analyzerOutputImag[i]
            analyzerMagnitudes[i] = sqrt(real * real + imag * imag) * magnitudeScale
        }

        mapSpectrumBands(into: destination)
    }

    /// 4-point, 3rd-order Hermite interpolation of a magnitude at a fractional
    /// bin position `x` between `y1` and `y2`.
    private static func hermite(_ x: Float, _ y0: Float, _ y1: Float, _ y2: Float, _ y3: Float) -> Float {
        let c0 = y1
        let c1 = 0.5 * (y2 - y0)
        let c3 = 1.5 * (y1 - y2) + 0.5 * (y3 - y0)
        let c2 = y0 - y1 + c1 - c3
        return ((c3 * x + c2) * x + c1) * x + c0
    }

    /// Fold `analyzerMagnitudes` into the 75 exponentially spaced bands starting
    /// at `destination` in `spectrum`.
    private func mapSpectrumBands(into destination: Int) {
        let bins = Self.analyzerBins
        let bands = Self.spectrumBandCount

        // Band edges run from bin 1 up to bin 253, doubling every twelve bands.
        let span = 255 / exp2(Float(bands) / 12)
        func edge(_ band: Int) -> Float { (exp2(Float(band) / 12) - 1) * span + 1 }

        var next = edge(0)
        for x in 0..<bands {
            var binF = next
            next = edge(x + 1)

            var bin = Int(binF)
            let end = min(Int(next), bins - 1)
            var mult = Float(bin + 1) - binF
            var interpolate = true
            var total: Float = 0

            repeat {
                if bin == end {
                    mult = next - binF
                    interpolate = true
                }
                if interpolate {
                    let c = bin < bins - 1 ? analyzerMagnitudes[bin + 1] : 0
                    let d = bin < bins - 2 ? analyzerMagnitudes[bin + 2] : 0
                    let value = Self.hermite(binF - Float(bin), analyzerMagnitudes[bin - 1], analyzerMagnitudes[bin], c, d)
                    total += value * mult
                } else {
                    total += analyzerMagnitudes[bin]
                }
                interpolate = false
                bin += 1
                binF = Float(bin)
            } while bin <= end

            // The interpolation can overshoot past a steep edge, so the low end
            // needs a floor as much as the high end needs a ceiling.
            spectrum[destination + x] = min(max(total, 0), 255).rounded(.towardZero)
        }
    }

    // MARK: - Butterchurn FFT Processing

    /// Recompute the Butterchurn spectrum and waveform from the full sample history.
    /// - Note: Uses pre-allocated buffers to avoid audio-thread allocations
    func processButterchurnFFT() {
        guard let setup = fftSetup else { return }

        let sampleCount = Self.butterchurnFFTSize
        let base = history.count - sampleCount
        for i in 0..<sampleCount {
            butterchurnReal[i] = history[base + i]
        }

        // Apply pre-computed Hann window to reduce spectral leakage
        vDSP_vmul(butterchurnReal, 1, hannWindow, 1, &butterchurnReal, 1, vDSP_Length(Self.butterchurnFFTSize))

        // Prepare split complex for FFT using pre-allocated buffers
        // For real-to-complex DFT, input is interleaved as even/odd
        for i in 0..<(Self.butterchurnFFTSize / 2) {
            fftInputReal[i] = butterchurnReal[i * 2]
            fftInputImag[i] = butterchurnReal[i * 2 + 1]
        }

        // Execute FFT into pre-allocated output buffers
        vDSP_DFT_Execute(setup, fftInputReal, fftInputImag, &fftOutputReal, &fftOutputImag)

        // Compute magnitude spectrum (first 1024 bins)
        // Magnitude = sqrt(real² + imag²)
        for i in 0..<Self.butterchurnBins {
            let real = fftOutputReal[i % fftOutputReal.count]
            let imag = fftOutputImag[i % fftOutputImag.count]
            var magnitude = sqrt(real * real + imag * imag)

            // Normalize and scale for visualization (0-1 range)
            magnitude /= Float(Self.butterchurnFFTSize)
            magnitude = min(1.0, magnitude * 4.0)  // Boost for visibility

            butterchurnSpectrum[i] = magnitude
        }

        // Capture waveform: downsample to 1024 samples
        let step = max(1, sampleCount / Self.butterchurnBins)
        for i in 0..<Self.butterchurnBins {
            let sampleIndex = min(i * step, sampleCount - 1)
            butterchurnWaveform[i] = history[base + sampleIndex]
        }
    }
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
    @ObservationIgnored private let sharedBuffer = VisualizerSharedBuffer()
    @ObservationIgnored private var pollTimer: Timer?

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
        let handler = Self.makeTapHandler(sharedBuffer: sharedBuffer, scratch: scratch)

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

    // MARK: - Poll Timer

    /// Poll period for draining the shared buffer, one tick per refresh of the
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
        guard let data = sharedBuffer.consume() else { return }
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
        sharedBuffer: VisualizerSharedBuffer,
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

            // Publish to shared buffer (non-blocking: drops frame on contention)
            let hopDuration = Double(VisualizerScratchBuffers.analyzerHop) / buffer.format.sampleRate
            _ = sharedBuffer.tryPublish(from: scratch, oscilloscopeSamples: 76, hopDuration: hopDuration)
        }
    }
    // swiftlint:enable function_body_length
}
