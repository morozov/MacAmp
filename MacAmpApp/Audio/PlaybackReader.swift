import AVFoundation
import os

/// Decodes a file into the player node a chunk at a time, analyzing each chunk
/// on the way through.
///
/// Handing an `AVAudioFile` to `scheduleSegment` keeps the decoded samples
/// inside the engine, which leaves a visualizer no source but a tap on the
/// output — audio that has already been rendered, delivered in 100 ms lumps.
/// Reading here instead puts the samples in reach exactly once: they are
/// analyzed and scheduled from the same buffer, so the analyzer sees the audio
/// before it is audible and nothing is decoded twice.
///
/// Reads run on a private serial queue. Everything the audio engine needs is
/// handed over through `AVAudioPlayerNode`, and everything the UI needs goes
/// through `SpectrumBandFeed`, both of which are safe to touch from there.
final class PlaybackReader: @unchecked Sendable {
    /// Frames per read. At 44.1 kHz this is a little over half a second, so a
    /// full queue holds enough audio to cover a slow disk without holding so
    /// much that a seek has to discard meaningful work.
    private static let chunkFrames: AVAudioFrameCount = 24576
    /// Chunks kept scheduled ahead of the playhead.
    private static let queueDepth = 4

    private let queue = DispatchQueue(label: "com.macamp.playback-reader", qos: .userInitiated)
    private let playerNode: AVAudioPlayerNode
    private let feed: SpectrumBandFeed
    private let analyzer = SpectrumBandAnalyzer()

    /// Called on the main actor once the last chunk of a run has been played.
    private let onEnded: @MainActor (UUID?) -> Void

    // Reader state, confined to `queue`.
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var nextFrame: AVAudioFramePosition = 0
    private var endFrame: AVAudioFramePosition = 0
    private var outputFormat: AVAudioFormat?
    private var seekID: UUID?
    private var generation: UInt64 = 0
    private var scheduledEnd = false

    /// Bumped by `stop()` so chunks in flight for a superseded position are
    /// dropped instead of scheduled.
    private let epoch = OSAllocatedUnfairLock(initialState: UInt64(0))

    /// Mono mixdown of the chunk being analyzed, plus the tail of the previous
    /// one so a window straddling the boundary still sees real samples.
    private var mono: [Float] = []
    private var carry: [Float] = []
    private var bands: [Float] = Array(repeating: 0, count: SpectrumBandAnalyzer.bandCount)

    init(
        playerNode: AVAudioPlayerNode,
        feed: SpectrumBandFeed,
        onEnded: @escaping @MainActor (UUID?) -> Void
    ) {
        self.playerNode = playerNode
        self.feed = feed
        self.onEnded = onEnded
    }

    /// Abandon the current run. Safe to call when nothing is running.
    func stop() {
        let next = epoch.withLock { state -> UInt64 in
            state &+= 1
            return state
        }
        feed.reset()
        queue.async { [weak self] in
            guard let self else { return }
            guard self.epoch.withLock({ $0 }) == next else { return }
            self.file = nil
            self.converter = nil
            self.seekID = nil
            self.scheduledEnd = true
            self.carry = []
        }
    }

    /// Begin decoding `url` from `startFrame`, stopping at `endFrame`.
    ///
    /// - Parameter outputFormat: The format the player node is connected with.
    ///   Chunks are converted into it when the file does not already match.
    func start(
        url: URL,
        startFrame: AVAudioFramePosition,
        endFrame: AVAudioFramePosition,
        outputFormat: AVAudioFormat,
        seekID: UUID?
    ) {
        let next = epoch.withLock { state -> UInt64 in
            state &+= 1
            return state
        }
        let generation = feed.reset()

        queue.async { [weak self] in
            guard let self else { return }
            guard self.epoch.withLock({ $0 }) == next else { return }

            do {
                // A private handle: the engine no longer reads the file, so this
                // is the only decoder running over it.
                let file = try AVAudioFile(forReading: url)
                file.framePosition = startFrame
                self.file = file
                self.nextFrame = startFrame
                self.endFrame = min(endFrame, file.length)
                self.outputFormat = outputFormat
                self.seekID = seekID
                self.generation = generation
                self.scheduledEnd = false
                self.carry = []

                let sourceFormat = file.processingFormat
                self.converter = sourceFormat == outputFormat ? nil : AVAudioConverter(from: sourceFormat, to: outputFormat)

                for _ in 0..<Self.queueDepth {
                    self.readAndScheduleChunk(epoch: next)
                }
            } catch {
                AppLog.error(.audio, "PlaybackReader: open failed: \(error)")
            }
        }
    }

    // MARK: - Reading

    private func readAndScheduleChunk(epoch expected: UInt64) {
        guard epoch.withLock({ $0 }) == expected else { return }
        guard !scheduledEnd, let file, let outputFormat else { return }

        let remaining = endFrame - nextFrame
        guard remaining > 0 else {
            finishRun(epoch: expected)
            return
        }

        let frames = AVAudioFrameCount(min(AVAudioFramePosition(Self.chunkFrames), remaining))
        let sourceFormat = file.processingFormat
        guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames) else { return }

        do {
            file.framePosition = nextFrame
            try file.read(into: source, frameCount: frames)
        } catch {
            AppLog.error(.audio, "PlaybackReader: read failed: \(error)")
            finishRun(epoch: expected)
            return
        }

        guard source.frameLength > 0 else {
            finishRun(epoch: expected)
            return
        }

        let chunkStartFrame = nextFrame
        nextFrame += AVAudioFramePosition(source.frameLength)

        analyze(source, startingAt: chunkStartFrame, sampleRate: sourceFormat.sampleRate)

        guard let scheduled = convert(source, to: outputFormat) else {
            finishRun(epoch: expected)
            return
        }

        let isLast = nextFrame >= endFrame
        if isLast { scheduledEnd = true }
        let completionSeekID = seekID

        playerNode.scheduleBuffer(
            scheduled,
            completionCallbackType: isLast ? .dataPlayedBack : .dataConsumed
        ) { [weak self] _ in
            guard let self else { return }
            if isLast {
                Task { @MainActor in
                    self.onEnded(completionSeekID)
                }
            } else {
                self.queue.async {
                    self.readAndScheduleChunk(epoch: expected)
                }
            }
        }
    }

    private func finishRun(epoch expected: UInt64) {
        guard !scheduledEnd else { return }
        scheduledEnd = true
        let completionSeekID = seekID
        Task { @MainActor in
            self.onEnded(completionSeekID)
        }
    }

    private func convert(_ source: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter else { return source }

        let ratio = format.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return source
        }

        if let conversionError {
            AppLog.error(.audio, "PlaybackReader: convert failed: \(conversionError)")
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }

    // MARK: - Analysis

    /// Emit one analyzer frame per hop across the chunk, stamped with the file
    /// time each window ends at.
    private func analyze(_ buffer: AVAudioPCMBuffer, startingAt startFrame: AVAudioFramePosition, sampleRate: Double) {
        guard sampleRate > 0, let channels = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let carried = carry.count

        mono.removeAll(keepingCapacity: true)
        mono.append(contentsOf: carry)
        mono.reserveCapacity(carried + frameCount)

        let scale = 1.0 / Float(max(1, channelCount))
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channels[channel][frame]
            }
            mono.append(sum * scale)
        }

        let hop = SpectrumBandAnalyzer.hop
        var end = carried + hop
        while end <= mono.count {
            analyzer.analyze(mono, endingAt: end, into: &bands, at: 0)
            // The window ends here, so this is the audio heard at that instant.
            let time = Double(startFrame + AVAudioFramePosition(end - carried)) / sampleRate
            feed.append(bands, at: time, generation: generation)
            end += hop
        }

        // Keep enough tail for the next chunk's first window to reach back into
        // real audio rather than into silence.
        let keep = min(mono.count, SpectrumBandAnalyzer.windowSize)
        carry = Array(mono.suffix(keep))
    }
}
