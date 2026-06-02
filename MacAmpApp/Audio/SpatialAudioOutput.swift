import AVFoundation
import Atomics
import CoreAudio
import CoreMedia
import Synchronization
import os

/// Plays the engine's output through `AVSampleBufferAudioRenderer`, which macOS spatializes.
///
/// The engine renders in offline manual mode. On each renderer request the feed renders a
/// chunk, wraps it as a `CMSampleBuffer` and enqueues it. EQ, balance and the visualizer
/// apply before the renderer's buffer and lag by its depth; volume applies after it.
///
/// A full flush tears down a renderer's audio pipeline, and with head-tracked spatial audio
/// rebuilding it takes about a second. A seek or track change therefore never flushes: the
/// renderer holding the old audio is muted and cut short a fraction of a second ahead, and
/// the new audio starts on a second renderer whose pipeline is idle but alive. The
/// synchronizer clock never jumps; file positions map onto it through an offset.
///
/// Feed state is confined to `feedQueue`.
final class SpatialAudioOutput: @unchecked Sendable {

    /// One of the two renderers taking turns on the synchronizer. Confined to `feedQueue`.
    private final class Lane: @unchecked Sendable {
        let renderer = AVSampleBufferAudioRenderer()
        /// Clock frame at which this renderer's enqueued audio ends.
        var tailEnd: Int64 = 0
        /// Whether the renderer has built its pipeline.
        var isWarm = false
    }

    /// The file position at the clock, as an offset from it.
    private struct Mapping {
        /// Reported until the feed places the first buffer of a run, and a floor after it.
        var anchorSeconds: Double = 0
        /// Clock frame minus file frame; nil until the feed places the first buffer of a run.
        var offset: Int64?
    }

    private let lanes = [Lane(), Lane()]
    private var activeIndex = 0
    private var active: Lane { lanes[activeIndex] }
    private var idle: Lane { lanes[1 - activeIndex] }
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let feedQueue = DispatchQueue(label: "com.macamp.spatial.feed", qos: .userInteractive)
    private var isRequesting = false
    private var autoFlushCount = 0
    private var outputConfigCount = 0

    private let sampleRate: Double
    private let chunkFrames = 1024
    /// Ceiling on how far ahead to enqueue. The feed renders this much in one
    /// burst after a seek, so it must stay below what `PlaybackReader` keeps
    /// scheduled.
    static let maxBufferAhead = 2.0
    /// A renderer refuses to cut its queue closer to the clock than its audio queue has
    /// already taken in: about 0.2 s on built-in speakers and 0.3 s on spatial AirPods.
    /// The cut is retried later in steps until the renderer accepts it.
    private var cutLeads: StrideThrough<Double> { stride(from: cutLeadFloor, through: max(1.0, cutLeadFloor), by: 0.01) }
    private var cutLeadFloor = 0.15
    /// Seconds of silence that build an idle renderer's pipeline before it is needed.
    private static let warmUpSeconds = 0.25

    // feedQueue-confined
    private var renderBlock: AVAudioEngineManualRenderingBlock?
    private var renderBuffer: AVAudioPCMBuffer?
    private var interleaved: [Float]
    private let formatDescription: CMAudioFormatDescription?
    private var nextSample: Int64 = 0 {
        didSet { frontier.store(nextSample, ordering: .relaxed) }
    }
    /// `nextSample`, readable off `feedQueue`.
    private let frontier = ManagedAtomic<Int64>(0)
    private let mapping = Mutex(Mapping())
    private var userVolume: Float = 1
    private var unmuteObserver: Any?
    /// Seconds of audio the source can render now; nil when unlimited.
    private var sourceAvailable: (@Sendable () -> Double)?
    /// Called on `feedQueue` when the source is short and everything enqueued
    /// has been heard, with the seconds the feed needs available.
    private var onSourceStarved: (@Sendable (Double) -> Void)?
    private var retryScheduled = false
    /// The active renderer's enqueued buffers not yet heard, oldest first,
    /// re-enqueued after a flush.
    private var pending: [CMSampleBuffer] = []
    private var observers: [NSObjectProtocol] = []

    #if DEBUG
    private var _enqueuedCount = 0
    /// Test seam: number of buffers pushed to the renderer so far.
    var enqueuedCount: Int { feedQueue.sync { _enqueuedCount } }
    /// Test seam: seconds the enqueued PTS frontier leads the audible clock.
    var leadSeconds: Double { feedQueue.sync { currentLead() } }
    /// Test seam: buffers enqueued with a PTS behind the audible clock.
    private var _pastPTSEnqueues = 0
    var pastPTSEnqueues: Int { feedQueue.sync { _pastPTSEnqueues } }
    /// Test seam: the lowest peak of any buffer enqueued since the last reanchor.
    private var _minBufferPeak: Float = .greatestFiniteMagnitude
    var minBufferPeak: Float { feedQueue.sync { _minBufferPeak } }
    /// Test seam: times the past-PTS clamp moved the frontier forward.
    private var _ptsClampsFired = 0
    var ptsClampsFired: Int { feedQueue.sync { _ptsClampsFired } }
    /// Test seam: automatic renderer flushes.
    var autoFlushCountSeam: Int { feedQueue.sync { autoFlushCount } }
    /// Test seam: output configuration changes.
    var outputConfigChanges: Int { feedQueue.sync { outputConfigCount } }
    /// Test seam: the active renderer, to post its notifications.
    var rendererForTesting: AVSampleBufferAudioRenderer { feedQueue.sync { active.renderer } }
    var rendererVolumeForTesting: Float { feedQueue.sync { active.renderer.volume } }
    /// Test seam: seconds between the audible clock and the first buffer
    /// re-enqueued after a flush.
    private var _firstRefillPTS: Double?
    var firstRefillOffset: Double? { feedQueue.sync { _firstRefillPTS } }
    /// Test seam: runs of 64+ zero frames enqueued since the last reanchor,
    /// after the first non-zero frame.
    private var _gapRuns = 0
    private var _zeroRun = 0
    private var _heardSignal = false
    var gapRuns: Int { feedQueue.sync { _gapRuns } }
    /// Test seam: the PTS frontier, in frames.
    var enqueuedFrontier: Int64 { feedQueue.sync { nextSample } }
    /// Test seam: cuts the renderer refused at every lead, which fell back to a full flush.
    private var _cutFallbacks = 0
    var cutFallbacks: Int { feedQueue.sync { _cutFallbacks } }
    /// Test seam: hand-overs from one renderer to the other.
    private var _switches = 0
    var switches: Int { feedQueue.sync { _switches } }
    /// Test seam: the active renderer stays muted until a tail it still holds plays out.
    var isHoldingMuteForTail: Bool { feedQueue.sync { unmuteObserver != nil } }
    /// Test seam: the clock frame at which the idle renderer's audio ends.
    var idleTailEnd: Int64 { feedQueue.sync { idle.tailEnd } }
    /// Test seam: the earliest lead a cut is tried at, in seconds.
    func setCutLeadFloorForTesting(_ seconds: Double) { feedQueue.sync { cutLeadFloor = seconds } }
    #endif

    init() {
        let rate = Self.defaultOutputSampleRate()
        self.sampleRate = rate
        self.interleaved = [Float](repeating: 0, count: chunkFrames * 2)
        self.formatDescription = Self.makeFormatDescription(sampleRate: rate)
        AppLog.info(.audio, "SpatialAudioOutput: render rate \(rate) Hz (matched to output device)")
        // `-SPATIAL_OFF YES` keeps this output path but leaves stereo unspatialized.
        let spatialOff = UserDefaults.standard.bool(forKey: "SPATIAL_OFF")
        if spatialOff {
            AppLog.info(.audio, "SpatialAudioOutput: spatialization OFF (stereo not spatialized) — diagnostic")
        }
        for lane in lanes {
            lane.renderer.allowedAudioSpatializationFormats = spatialOff ? .multichannel : .monoStereoAndMultichannel
            synchronizer.addRenderer(lane.renderer)
        }
        applyVolume()
        // Holding the clock after a flush keeps the shared spatial session negotiating,
        // which glitches every other spatial app on the device.
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false

        for lane in lanes {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSNotification.Name("AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification"),
                object: lane.renderer, queue: nil
            ) { [weak self, weak lane] _ in
                guard let lane else { return }
                self?.handleAutoFlush(of: lane)
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSNotification.Name("AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification"),
                object: lane.renderer, queue: nil
            ) { [weak self, weak lane] _ in
                guard let lane else { return }
                self?.handleOutputConfigChange(of: lane)
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let unmuteObserver { synchronizer.removeTimeObserver(unmuteObserver) }
    }

    private func handleAutoFlush(of lane: Lane) {
        feedQueue.async {
            self.autoFlushCount += 1
            self.recover(lane)
            AppLog.error(.audio, "SpatialAudioOutput: renderer auto-flushed (total=\(self.autoFlushCount))")
        }
    }

    /// After an output configuration change the renderer must be flushed and
    /// refilled from the playhead.
    private func handleOutputConfigChange(of lane: Lane) {
        feedQueue.async {
            self.outputConfigCount += 1
            self.recover(lane)
            AppLog.error(.audio, "SpatialAudioOutput: output config changed (total=\(self.outputConfigCount))")
        }
    }

    /// The active renderer is refilled from the audible position; an idle one has
    /// nothing worth keeping. Both are flushed, since buffers enqueued around an
    /// automatic flush can survive it.
    private func recover(_ lane: Lane) {
        guard lane === active else {
            lane.renderer.flush()
            lane.tailEnd = 0
            lane.isWarm = false
            return
        }
        refillAfterFlush()
    }

    /// Flush the renderer and re-enqueue the unheard buffers from the audible
    /// position. The feed stops first: a callback firing during the renderer's
    /// reconfiguration blocks coreaudiod's format change for other apps.
    private func refillAfterFlush() {
        let renderer = active.renderer
        let wasRequesting = isRequesting
        isRequesting = false
        renderer.stopRequestingMediaData()
        renderer.flush()

        let now = synchronizer.currentTime()
        let retained = pending
        pending = []
        for buffer in retained {
            let start = CMSampleBufferGetPresentationTimeStamp(buffer)
            let count = CMSampleBufferGetNumSamples(buffer)
            var skip = 0
            if now.isNumeric {
                skip = Int(((now.seconds - start.seconds) * sampleRate).rounded(.down))
            }
            if skip >= count { continue }
            var trimmed = buffer
            if skip > 0 {
                var copy: CMSampleBuffer?
                guard CMSampleBufferCopySampleBufferForRange(
                    allocator: kCFAllocatorDefault, sampleBuffer: buffer,
                    sampleRange: CFRange(location: skip, length: count - skip),
                    sampleBufferOut: &copy) == noErr, let copy else { continue }
                trimmed = copy
            }
            renderer.enqueue(trimmed)
            pending.append(trimmed)
            #if DEBUG
            if _firstRefillPTS == nil { _firstRefillPTS = CMSampleBufferGetPresentationTimeStamp(trimmed).seconds - now.seconds }
            #endif
        }

        if wasRequesting { ensureFeeding() }
    }

    /// The format to enable manual rendering with.
    var renderingFormat: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    }
    var maximumFrameCount: AVAudioFrameCount { AVAudioFrameCount(chunkFrames) }

    /// Audible position in seconds within the file or stream, set by each reanchor.
    var currentTimeSeconds: Double {
        let mapping = mapping.withLock { $0 }
        guard let offset = mapping.offset else { return mapping.anchorSeconds }
        return max(mapping.anchorSeconds, Double(clockFrame() - offset) / sampleRate)
    }

    /// Seconds of audio enqueued ahead of what is being heard. Safe from any thread.
    var bufferedAheadSeconds: Double {
        max(0, Double(frontier.load(ordering: .relaxed) - clockFrame()) / sampleRate)
    }

    /// Bind to the engine's render block and format. Call each time manual rendering
    /// is enabled; a reconfigured engine can hand out a new block.
    func bind(renderBlock block: @escaping AVAudioEngineManualRenderingBlock, format: AVAudioFormat) {
        nonisolated(unsafe) let block = block
        feedQueue.sync {
            self.renderBlock = block
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkFrames))
            buffer?.frameLength = AVAudioFrameCount(chunkFrames)
            self.renderBuffer = buffer
        }
    }

    // MARK: - Transport (main actor)

    /// Output volume, 0...1. The renderer applies it after its buffer, so changes are
    /// heard without the buffer's delay.
    func setVolume(_ volume: Float) {
        feedQueue.sync {
            userVolume = volume
            applyVolume()
        }
    }

    /// Begin/continue audible playback. Starts the clock and arms the feed.
    /// Caller must have started the engine and player node, with audio scheduled
    /// on it (playAudio does), or the feed renders silence.
    func play() {
        // Setting the rate it already runs at still restarts the audio queue.
        if synchronizer.rate != 1 { synchronizer.rate = 1 }
        feedQueue.async { self.warmIdle() }
        ensureFeeding()
    }

    /// Hold playback; the buffered lead resumes on the next `play()`.
    func pause() {
        synchronizer.rate = 0.0
    }

    /// Stop and drop all buffered audio, holding the position.
    func stop() {
        synchronizer.rate = 0.0
        feedQueue.sync {
            let held = currentTimeSeconds
            cutActive()
            beginRun(at: held)
        }
    }

    /// Arm the renderer's data requests; idempotent.
    func ensureFeeding() {
        guard !isRequesting else { return }
        isRequesting = true
        active.renderer.requestMediaDataWhenReady(on: feedQueue) { [weak self] in
            self?.fill()
        }
    }

    /// Limit pulls to what the source can supply. The source then never reads
    /// dry, so `onStarved` reports underruns.
    func setSourceAvailability(
        _ provider: (@Sendable () -> Double)?,
        onStarved: (@Sendable (Double) -> Void)? = nil
    ) {
        feedQueue.sync {
            self.sourceAvailable = provider
            self.onSourceStarved = onStarved
        }
    }

    private func fill() {
        guard isRequesting else { return }
        let chunkSeconds = Double(chunkFrames) / sampleRate
        let renderer = active.renderer
        while renderer.isReadyForMoreMediaData {
            if currentLead() >= Self.maxBufferAhead { break }
            // Two chunks of margin: the engine's resampler reads slightly
            // ahead of the frames it outputs.
            if let sourceAvailable, sourceAvailable() < 2 * chunkSeconds {
                if currentLead() <= 0 { onSourceStarved?(2 * chunkSeconds) }
                // The renderer won't call again while it is still ready.
                if !retryScheduled {
                    retryScheduled = true
                    feedQueue.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                        self?.retryScheduled = false
                        self?.fill()
                    }
                }
                break
            }
            if !renderOne() { break }
        }
    }

    /// Stop pulling the engine, waiting out a pull in progress. Call before
    /// reconfiguring the graph.
    func suspendFeed() {
        guard isRequesting else { return }
        isRequesting = false
        active.renderer.stopRequestingMediaData()
        feedQueue.sync {}
    }

    /// Seconds of audio enqueued ahead of the audible playback position.
    private func currentLead() -> Double {
        Double(nextSample - clockFrame()) / sampleRate
    }

    /// The synchronizer clock in output frames.
    private func clockFrame() -> Int64 {
        let t = synchronizer.currentTime()
        return t.isNumeric ? Int64((t.seconds * sampleRate).rounded(.down)) : 0
    }

    /// Drop buffered audio; the next buffer the feed renders plays `seconds` into the
    /// source, as soon as the output can take it.
    func reanchor(toSeconds seconds: Double) {
        feedQueue.sync {
            cutActive()
            beginRun(at: seconds)
        }
    }

    // MARK: - Hand-over (feedQueue)

    /// End what the active renderer still holds near the clock. A renderer holding audio
    /// ahead of the clock is muted, cut short and left to run dry; the idle one takes over.
    private func cutActive() {
        isRequesting = false
        let lane = active
        lane.renderer.stopRequestingMediaData()
        pending = []
        let now = clockFrame()
        guard nextSample > now else { return }
        lane.renderer.volume = 0
        lane.tailEnd = cut(lane, at: now)
        activeIndex = 1 - activeIndex
        applyVolume()
        #if DEBUG
        _switches += 1
        #endif
    }

    /// Drops the lane's audio past the earliest point the renderer accepts, and returns
    /// the clock frame its audio now ends at.
    private func cut(_ lane: Lane, at now: Int64) -> Int64 {
        let end = nextSample
        let chunk = Int64(chunkFrames)
        cutting: for lead in cutLeads {
            let target = now + Int64(lead * sampleRate)
            if target >= end { return end }
            // Buffers are chunk-sized and end at the frontier, so cut on a boundary.
            let boundary = end - (end - target) / chunk * chunk
            switch flush(lane.renderer, from: boundary) {
            case .accepted: return boundary
            case .refused: continue
            // A full flush supersedes the outstanding one.
            case .timedOut: break cutting
            }
        }
        AppLog.warn(.audio, "SpatialAudioOutput: renderer did not accept a cut; flushing it")
        lane.renderer.flush()
        lane.isWarm = false
        #if DEBUG
        _cutFallbacks += 1
        #endif
        return 0
    }

    private enum CutResult { case accepted, refused, timedOut }

    /// Ask the renderer to drop its buffers from `frame` on. It answers within a millisecond.
    private func flush(_ renderer: AVSampleBufferAudioRenderer, from frame: Int64) -> CutResult {
        let done = DispatchSemaphore(value: 0)
        let flushed = ManagedAtomic(false)
        renderer.flush(fromSourceTime: CMTime(value: frame, timescale: Int32(sampleRate))) { succeeded in
            flushed.store(succeeded, ordering: .relaxed)
            done.signal()
        }
        guard done.wait(timeout: .now() + 0.1) == .success else { return .timedOut }
        return flushed.load(ordering: .relaxed) ? .accepted : .refused
    }

    /// Start a run: the feed places its first buffer and fixes the mapping.
    private func beginRun(at seconds: Double) {
        nextSample = clockFrame()
        mapping.withLock { $0 = Mapping(anchorSeconds: seconds, offset: nil) }
        #if DEBUG
        _minBufferPeak = .greatestFiniteMagnitude
        _gapRuns = 0
        _zeroRun = 0
        _heardSignal = false
        #endif
    }

    /// The idle renderer is silent. The active one plays at the user's volume once any
    /// muted tail it still holds has played out.
    private func applyVolume() {
        if let unmuteObserver {
            synchronizer.removeTimeObserver(unmuteObserver)
            self.unmuteObserver = nil
        }
        idle.renderer.volume = 0
        let tail = active.tailEnd
        guard tail <= clockFrame() else {
            active.renderer.volume = 0
            let time = NSValue(time: CMTime(value: tail, timescale: Int32(sampleRate)))
            unmuteObserver = synchronizer.addBoundaryTimeObserver(forTimes: [time], queue: feedQueue) { [weak self] in
                self?.applyVolume()
            }
            return
        }
        active.renderer.volume = UnitTestSupport.isActive ? 0 : userVolume
    }

    /// Build the idle renderer's pipeline with a moment of silence, so the first hand-over
    /// to it does not wait for one.
    private func warmIdle() {
        let lane = idle
        guard !lane.isWarm, let formatDescription else { return }
        // After any muted tail it still holds, which must stay muted to its end.
        var pts = max(clockFrame() + Int64(startLead() * sampleRate), lane.tailEnd)
        let silence = [Float](repeating: 0, count: chunkFrames * 2)
        for _ in 0..<Int((Self.warmUpSeconds * sampleRate).rounded(.up)) / chunkFrames + 1 {
            guard let buffer = makeSampleBuffer(silence, at: pts, format: formatDescription) else { return }
            lane.renderer.enqueue(buffer)
            pts += Int64(chunkFrames)
        }
        lane.tailEnd = pts
        lane.isWarm = true
    }

    /// How far past the clock a renderer that ran dry still plays a new buffer: about the
    /// output's latency. Earlier buffers are discarded.
    private func startLead() -> Double {
        Self.defaultOutputIsBuiltIn() ? 0.05 : 0.15
    }

    // MARK: - Feed (feedQueue)

    private var loggedRenderError = false

    private func renderOne() -> Bool {
        guard let renderBlock, let renderBuffer, let formatDescription else { return false }

        let clock = clockFrame()
        var clampAttempted = false
        if mapping.withLock({ $0.offset }) == nil {
            // First buffer of a run.
            let start = max(clock + Int64(startLead() * sampleRate), active.tailEnd)
            nextSample = start
            mapping.withLock { $0.offset = start - Int64(($0.anchorSeconds * sampleRate).rounded()) }
        } else {
            // The renderer plays past-PTS buffers as a fast catch-up burst, so after an
            // underrun the frontier moves to now, and the file position with it.
            clampAttempted = true
            if clock > nextSample {
                let skipped = clock - nextSample
                nextSample = clock
                mapping.withLock { $0.offset? += skipped }
                #if DEBUG
                _ptsClampsFired += 1
                #endif
            }
        }

        var err: OSStatus = noErr
        let status = renderBlock(AVAudioFrameCount(chunkFrames), renderBuffer.mutableAudioBufferList, &err)
        guard status == .success, let ch = renderBuffer.floatChannelData else {
            if !loggedRenderError {
                loggedRenderError = true
                AppLog.error(.audio, "SpatialAudioOutput: manualRenderingBlock failed status=\(status.rawValue) err=\(err)")
            }
            return false
        }

        let left = ch[0], right = ch[1]
        for i in 0..<chunkFrames {
            interleaved[i * 2] = left[i]
            interleaved[i * 2 + 1] = right[i]
        }

        if clampAttempted {
            let localLead = Double(nextSample - clock) / sampleRate
            if localLead < -0.01 {
                #if DEBUG
                _pastPTSEnqueues += 1
                #endif
            }
        }
        guard let sb = makeSampleBuffer(interleaved, at: nextSample, format: formatDescription) else { return false }

        active.renderer.enqueue(sb)
        active.isWarm = true
        nextSample += Int64(chunkFrames)
        pending.removeAll { buffer in
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            return pts.value + Int64(CMSampleBufferGetNumSamples(buffer)) <= clock
        }
        pending.append(sb)
        #if DEBUG
        _enqueuedCount += 1
        let bufPeak = interleaved.max(by: { abs($0) < abs($1) }).map { abs($0) } ?? 0
        if bufPeak < _minBufferPeak { _minBufferPeak = bufPeak }
        for i in 0..<chunkFrames {
            if interleaved[i * 2] != 0 {
                _heardSignal = true
                _zeroRun = 0
            } else if _heardSignal {
                _zeroRun += 1
                if _zeroRun == 64 { _gapRuns += 1 }
            }
        }
        #endif
        return true
    }

    /// One chunk of interleaved stereo at `pts`, in output frames.
    private func makeSampleBuffer(_ samples: [Float], at pts: Int64, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let byteCount = chunkFrames * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == kCMBlockBufferNoErr,
            let blockBuffer = block else { return nil }

        var dataPtr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: nil, dataPointerOut: &dataPtr) == kCMBlockBufferNoErr,
            let dst = dataPtr else { return nil }
        samples.withUnsafeBytes { src in
            _ = memcpy(dst, src.baseAddress!, byteCount)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: CMTime(value: pts, timescale: Int32(sampleRate)),
            decodeTimeStamp: .invalid)
        var sampleSize = 8
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: format, sampleCount: chunkFrames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }

    private static func makeFormatDescription(sampleRate: Double) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var desc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &desc)
        return desc
    }

    /// The default output device, or nil if it can't be read.
    private static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &deviceAddr, 0, nil, &deviceSize, &deviceID) == noErr,
              deviceID != 0 else { return nil }
        return deviceID
    }

    /// Nominal rate of the default output device, or 48 kHz if it can't be read.
    private static func defaultOutputSampleRate() -> Double {
        guard let deviceID = defaultOutputDevice() else { return 48_000 }
        var rate = Float64(0)
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &rateAddr, 0, nil, &rateSize, &rate) == noErr,
              rate > 0 else { return 48_000 }
        return rate
    }

    /// Whether the default output is a built-in device, whose latency is a few milliseconds.
    private static func defaultOutputIsBuiltIn() -> Bool {
        guard let deviceID = defaultOutputDevice() else { return false }
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBuiltIn
    }
}
