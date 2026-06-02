import AVFoundation
import Atomics
import os
#if SWIFT_PACKAGE
import AudioWorkgroupShim
#endif

/// Snapshot of pre-reconfiguration engine + bridge state, captured by
/// `AudioEngineController.handleEngineWillReconfigure()` and forwarded to
/// AudioPlayer via `onEngineWillReconfigure`. AudioPlayer uses these fields to
/// decide whether to resume after the rewire and from which time position.
///
/// Captured at notification time, so `wasPlaying` may already reflect
/// post-reconfigure state (the engine auto-stops on output route change). The
/// bridge flags are MacAmp-owned and stay accurate; `currentTime` is best-effort
/// from `playerNode.lastRenderTime`.
struct PreReconfigureSnapshot: Sendable {
    let wasPlaying: Bool
    let wasPaused: Bool  // engine can't know; AudioPlayer supplies it
    let currentTime: Double
    let wasStreamBridge: Bool
}

/// Owns the AVAudioEngine graph and all node-level operations.
///
/// Responsibilities:
/// - Engine setup, graph wiring (local file + stream bridge paths)
/// - Audio scheduling (scheduleFrom)
/// - Stream bridge lifecycle (activate/deactivate with format invariants)
/// - Visualizer tap install/remove
/// - Node-level transport (play/pause/stop on playerNode)
/// - Progress timer
///
/// AudioPlayer retains ownership of:
/// - Playback state machine (seek guards, completion filtering)
/// - Track management and playlist navigation
/// - Video playback routing
/// - All public API forwarding (facade pattern)
@MainActor
final class AudioEngineController {

    // MARK: - Engine Internals

    let audioEngine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()

    /// The engine renders into this, which plays through `AVSampleBufferAudioRenderer`
    /// so macOS spatial audio can engage.
    let spatialOutput = SpatialAudioOutput()
    private(set) var audioFile: AVAudioFile?
    private var progressTimer: Timer?
    private var playheadOffset: Double = 0

    /// Format the player node is connected with, which chunks must arrive in.
    private var graphFormat: AVAudioFormat?
    private var reader: PlaybackReader!

    // Manual rendering never fires `.dataPlayedBack`, so the progress timer detects
    // the end from the audible clock.
    private var scheduledEndSeconds: Double = .infinity
    private var scheduledSeekID: UUID?
    private var endFired = false

    // Output starts once the reader has scheduled audio; until then the
    // player renders silence.
    private var scheduleGeneration = 0
    private var isSourcePrimed = false
    private var playWhenPrimed = false

    /// Seconds elapsed in the loaded file at the current render time. 0
    /// when nothing is loaded or playback hasn't begun. Rate-agnostic —
    /// callers multiply by whichever sample rate their frame coordinate
    /// uses (e.g. `AudioPlayer` uses the file's source `mSampleRate`,
    /// which can differ from `AVAudioFile.processingFormat.sampleRate`
    /// for HE-AAC SBR files).
    var currentPlaybackSeconds: Double {
        spatialOutput.currentTimeSeconds
    }

    /// The position analyzer frames are stamped against: the file's playhead, or
    /// while a stream is playing, the ring buffer's read head less what the
    /// output holds ahead of the listener.
    var spectrumPlaybackSeconds: Double {
        if isBridgeActive, let ring = streamRingBuffer, streamSampleRate > 0 {
            return Double(ring.readHeadFrames) / streamSampleRate - spatialOutput.bufferedAheadSeconds
        }
        return currentPlaybackSeconds
    }

    /// True while the stream bridge is rendering silence: gated off, rebuffering,
    /// or with nothing left to play. The analyzer shows no bars then, as it does
    /// for a file that is not playing.
    var isStreamSilent: Bool {
        guard isBridgeActive, let ring = streamRingBuffer else { return false }
        return (streamSilenceGate?.load(ordering: .relaxed) ?? 0) != 0
            || ring.isRebuffering
            || ring.availableFrames == 0
    }

    // MARK: - Stream Bridge State

    private var streamSourceNode: AVAudioSourceNode?
    private var streamRingBuffer: LockFreeRingBuffer?
    private var streamSampleRate: Float64 = 0
    /// Bridge-scoped silence gate. Single writer (MainActor `setStreamSilenced`,
    /// releasing store), single reader (render block, acquiring load).
    private var streamSilenceGate: ManagedAtomic<UInt8>?
    private(set) var isBridgeActive: Bool = false

    // MARK: - Engine Configuration Observer

    private let configObserver: AudioEngineConfigurationObserver

    // MARK: - Injected Dependencies

    private let eqNode: AVAudioUnitEQ
    private let visualizerPipeline: VisualizerPipeline

    // MARK: - Callbacks to AudioPlayer

    /// Called on every progress timer tick with (currentTime, progress).
    var onProgressUpdate: ((_ currentTime: Double, _ progress: Double) -> Void)?

    /// Called when a scheduled audio segment completes. The UUID identifies the seek operation
    /// that scheduled the segment, allowing AudioPlayer to filter stale completions.
    var onPlaybackEnded: ((_ fromSeekID: UUID?) -> Void)?

    /// Called when isBridgeActive changes so AudioPlayer can update its observable property.
    var onBridgeStateChanged: ((_ isActive: Bool) -> Void)?

    /// Called at the START of an output-route reconfigure burst, before any rewire.
    /// AudioPlayer arms `seekGuardActive` and bumps `currentSeekID` here so the
    /// stale playerNode completion (that the impending engine restart will fire)
    /// is filtered. Snapshot fields let AudioPlayer reconstruct resume state in
    /// the matching `onEngineDidReconfigure` callback.
    var onEngineWillReconfigure: ((PreReconfigureSnapshot) -> Void)?

    /// Called once after the route change has settled (150 ms quiet window).
    /// Engine has been restarted and bridge connections refreshed; AudioPlayer
    /// re-applies volume/balance, reschedules from the saved position, and
    /// PlaybackCoordinator refreshes the stream workgroup.
    var onEngineDidReconfigure: (() -> Void)?

    // MARK: - Init

    init(eqNode: AVAudioUnitEQ, visualizerPipeline: VisualizerPipeline) {
        self.eqNode = eqNode
        self.visualizerPipeline = visualizerPipeline
        self.configObserver = AudioEngineConfigurationObserver(engine: audioEngine)
        setupEngine()
        reader = PlaybackReader(
            playerNode: playerNode,
            feed: visualizerPipeline.analyzerFeed
        ) { [weak self] seekID in
            self?.onPlaybackEnded?(seekID)
        }
        configObserver.onWillReconfigure = { [weak self] in
            self?.handleEngineWillReconfigure()
        }
        configObserver.onDidReconfigure = { [weak self] in
            self?.handleEngineDidReconfigure()
        }
        configObserver.start()
    }

    /// Tear down engine resources. Called from AudioPlayer's isolated deinit.
    func shutdown() {
        configObserver.stop()
        progressTimer?.invalidate()
        spatialOutput.suspendFeed()
        spatialOutput.stop()
        deactivateStreamBridge()
        visualizerPipeline.removeTap()
    }

    /// Put the engine into offline manual rendering mode and bind the output to
    /// its render block. Must run while the engine is stopped; idempotent. A
    /// reset can clear the mode, so this is re-checked before each start.
    private func ensureManualRendering() {
        guard !audioEngine.isInManualRenderingMode else { return }
        do {
            try audioEngine.enableManualRenderingMode(
                .offline,
                format: spatialOutput.renderingFormat,
                maximumFrameCount: spatialOutput.maximumFrameCount
            )
            spatialOutput.bind(renderBlock: audioEngine.manualRenderingBlock,
                               format: audioEngine.manualRenderingFormat)
            AppLog.info(.audio, "Manual rendering enabled — spatial output active (\(audioEngine.manualRenderingFormat.sampleRate)Hz)")
        } catch {
            AppLog.error(.audio, "enableManualRenderingMode failed: \(error)")
        }
    }

    // MARK: - Engine Setup

    private func setupEngine() {
        audioEngine.attach(playerNode)
        audioEngine.attach(eqNode)
        // Up front, so graph rewires read the render rate from `outputNode`.
        ensureManualRendering()
    }

    // MARK: - Graph Wiring (Local File Path)

    /// Rewire the engine graph for local file playback.
    /// Deactivates stream bridge if active, reconnects playerNode → EQ → mixer → output.
    ///
    /// **Critical:** Uses EXPLICIT format (never nil) to avoid -10868 format stickiness
    /// after stream bridge disconnection.
    func rewireForFile(_ file: AVAudioFile) {
        audioFile = file

        // Pause the manual-render pull while the graph is reconfigured.
        spatialOutput.suspendFeed()

        // Deactivate stream bridge if active
        if isBridgeActive {
            deactivateStreamBridge()
        }

        // Stop engine if running (between tracks)
        if audioEngine.isRunning {
            audioEngine.stop()
        }

        // Clear all existing connections
        audioEngine.disconnectNodeInput(eqNode, bus: 0)
        audioEngine.disconnectNodeOutput(playerNode)
        audioEngine.disconnectNodeOutput(eqNode)

        // Reconnect with EXPLICIT format — never use nil after stream bridge
        let outputSampleRate = audioEngine.outputNode.inputFormat(forBus: 0).sampleRate
        let fileChannels = file.processingFormat.channelCount
        let graphFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: fileChannels,
            interleaved: false
        )!
        audioEngine.connect(playerNode, to: eqNode, format: graphFormat)
        audioEngine.connect(eqNode, to: audioEngine.mainMixerNode, format: graphFormat)
        self.graphFormat = graphFormat

        // Verify mixer→output
        if audioEngine.outputConnectionPoints(for: audioEngine.mainMixerNode, outputBus: 0).isEmpty {
            audioEngine.connect(audioEngine.mainMixerNode, to: audioEngine.outputNode, format: nil)
        }

        audioEngine.prepare()
        startEngineIfNeeded()
        installVisualizerTapIfNeeded()
    }

    // MARK: - Audio Scheduling

    /// Schedules audio playback from a specific time, optionally bounded by an end time.
    /// - Parameters:
    ///   - time: Absolute start time within the loaded file (seconds).
    ///   - endTime: Optional absolute end time; when non-nil, the scheduled segment ends here
    ///     and the completion handler fires at that boundary. Used by CUE slice playback to
    ///     trigger track advance at the slice end rather than at EOF.
    ///   - seekID: Completion-handler tag for stale-completion filtering.
    /// - Returns: `true` if audio was scheduled, `false` if the start is at or past EOF (or past `endTime`).
    func scheduleFrom(time: Double, endTime: Double? = nil, seekID: UUID?) -> Bool {
        guard let file = audioFile else {
            AppLog.warn(.audio, "scheduleFrom: No audio file loaded")
            return false
        }

        let sampleRate = file.processingFormat.sampleRate
        let fileDuration = Double(file.length) / sampleRate

        // A feed pulling the stopped player would enqueue silence.
        spatialOutput.suspendFeed()
        playWhenPrimed = false
        isSourcePrimed = false
        scheduleGeneration += 1
        let generation = scheduleGeneration

        // Everything queued for the old position describes audio that will not
        // be heard, so the analyzer must forget it before the reader refills.
        reader.stop()

        // If seeking to or past the end, trigger completion immediately
        if time >= fileDuration - 0.01 {
            playheadOffset = fileDuration
            playerNode.stop()
            return false
        }

        let clampedStart = max(0, min(time, fileDuration))
        let startFrame = AVAudioFramePosition(clampedStart * sampleRate)

        // Determine end frame: bounded by endTime if provided, otherwise EOF.
        let endFrame: AVAudioFramePosition
        if let endTime {
            let clampedEnd = max(clampedStart, min(endTime, fileDuration))
            endFrame = AVAudioFramePosition(clampedEnd * sampleRate)
        } else {
            endFrame = file.length
        }

        let framesRemaining = max(0, endFrame - startFrame)

        playheadOffset = Double(startFrame) / sampleRate
        playerNode.stop()

        if framesRemaining > 0 {
            reader.start(
                url: file.url,
                startFrame: startFrame,
                endFrame: endFrame,
                outputFormat: graphFormat ?? file.processingFormat,
                seekID: seekID
            ) { [weak self] in
                guard let self, self.scheduleGeneration == generation else { return }
                self.isSourcePrimed = true
                if self.playWhenPrimed {
                    self.playWhenPrimed = false
                    self.spatialOutput.play()
                }
            }

            scheduledEndSeconds = Double(endFrame) / sampleRate
            scheduledSeekID = seekID
            endFired = false

            // Drop audio rendered for the old position and move the clock to the new one.
            spatialOutput.reanchor(toSeconds: playheadOffset)
            return true
        } else {
            onPlaybackEnded?(nil)
            return false
        }
    }

    /// The duration of the currently loaded audio file in seconds.
    var currentFileDuration: Double {
        guard let file = audioFile else { return 0 }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return Double(file.length) / sampleRate
    }

    /// The URL of the currently loaded audio file, or nil if none.
    /// Used by CUE-slice playback to skip a reload when consecutive slices share a file.
    var currentFileURL: URL? { audioFile?.url }

    // MARK: - Audio Workgroup

    /// The audio IO workgroup from the output node. Only valid while engine is running.
    /// Used by StreamDecodePipeline to join its decode thread to the real-time workgroup.
    /// Requires ObjC shim because AUAudioUnit.osWorkgroup is Swift-unavailable.
    var audioWorkgroup: os_workgroup_t? {
        guard audioEngine.isRunning else { return nil }
        return AUAudioUnitGetWorkgroup(audioEngine.outputNode.auAudioUnit)
    }

    // MARK: - Engine Lifecycle

    /// Start the audio engine if not running. Returns true if engine is running after call.
    @discardableResult
    func startEngineIfNeeded() -> Bool {
        if !audioEngine.isRunning {
            ensureManualRendering()
            audioEngine.prepare()
            do {
                try audioEngine.start()
            } catch {
                AppLog.error(.audio, "AudioEngine start error: \(error)")
                return false
            }
        }
        return audioEngine.isRunning
    }

    #if DEBUG
    /// Test seam: the volume of the audio reaching the device.
    var deviceOutputVolumeForTesting: Float? { spatialOutput.rendererVolumeForTesting }
    #endif

    // MARK: - Progress Timer

    func startProgressTimer() {
        progressTimer?.invalidate()
        // .common run-loop mode keeps this firing during user gestures (.eventTracking).
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            dispatchPrecondition(condition: .onQueue(.main))
            MainActor.assumeIsolated {
                guard let self = self else { return }
                let current = self.spatialOutput.currentTimeSeconds
                let duration = self.currentFileDuration
                let progress = duration > 0 ? current / duration : 0
                self.onProgressUpdate?(current, progress)

                // Stop pulling once the end is heard, or the feed enqueues silence indefinitely.
                if !self.endFired, current >= self.scheduledEndSeconds {
                    self.endFired = true
                    self.onPlaybackEnded?(self.scheduledSeekID)
                    self.spatialOutput.suspendFeed()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    func invalidateProgressTimer() {
        progressTimer?.invalidate()
    }

    // MARK: - Visualizer Tap

    func installVisualizerTapIfNeeded() {
        guard !visualizerPipeline.isTapInstalled else { return }
        visualizerPipeline.installTap(on: audioEngine.mainMixerNode)
    }

    func removeVisualizerTapIfNeeded() {
        visualizerPipeline.removeTap()
        visualizerPipeline.clearData()
    }

    // MARK: - Audio Transport (node-level)

    var isPlayerNodePlaying: Bool { playerNode.isPlaying }

    func playAudio() {
        _ = startEngineIfNeeded()
        if !playerNode.isPlaying {
            playerNode.play()
        }
        if isBridgeActive || isSourcePrimed {
            spatialOutput.play()
        } else {
            playWhenPrimed = true
        }
    }

    func pauseAudio() {
        playWhenPrimed = false
        playerNode.pause()
        spatialOutput.pause()
    }

    func stopAudio() {
        playWhenPrimed = false
        reader.stop()
        playerNode.stop()
        spatialOutput.pause()
    }

    // MARK: - Volume / Balance

    func setVolume(_ volume: Float) {
        // Volume applies at the renderer, after its buffer, so changes are heard at once.
        playerNode.volume = 1.0
        streamSourceNode?.volume = 1.0
        spatialOutput.setVolume(volume)
    }

    func setBalance(_ balance: Float) {
        playerNode.pan = balance
        streamSourceNode?.pan = balance
    }

    /// Silence the stream render block. No-op when bridge is inactive.
    /// Producer side must be quiesced and ring flushed BEFORE clearing.
    func setStreamSilenced(_ silenced: Bool) {
        guard let gate = streamSilenceGate else { return }
        let wasSilenced = gate.load(ordering: .relaxed) != 0
        gate.store(silenced ? 1 : 0, ordering: .releasing)
        guard silenced != wasSilenced else { return }

        // The output still holds audio rendered before the gate closed.
        spatialOutput.suspendFeed()
        if silenced {
            spatialOutput.stop()
        } else {
            spatialOutput.reanchor(toSeconds: spatialOutput.currentTimeSeconds)
            spatialOutput.play()
        }
    }

    #if DEBUG
    /// Test seam: chunks the playback reader has handed to the player node.
    var scheduledChunkCountForTesting: Int { reader.scheduledChunkCountForTesting }

    /// Test seam: observe what file playback sends toward the output, ahead of
    /// the mixer the visualizer taps, with the output itself silenced.
    func installOutputTapForTesting(_ block: @escaping AVAudioNodeTapBlock) {
        audioEngine.mainMixerNode.outputVolume = 0
        eqNode.removeTap(onBus: 0)
        eqNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: block)
    }

    func removeOutputTapForTesting() {
        eqNode.removeTap(onBus: 0)
    }

    /// Test seam: the engine's render position. Nodes report no render time in
    /// manual rendering.
    var outputSampleTimeForTesting: AVAudioFramePosition? { audioEngine.manualRenderingSampleTime }

    var isStreamSilenceGateActive: Bool {
        (streamSilenceGate?.load(ordering: .relaxed) ?? 0) != 0
    }
    #endif

    // MARK: - Stream Bridge

    /// Render block for AVAudioSourceNode. MUST be nonisolated static — runs on the RT thread.
    /// Reads interleaved Float32 from `ringBuffer`; zero-fills + sets `isSilence=true` while
    /// `silenceGate` is non-zero (closes the pause window where decoded PCM is still in the ring).
    private nonisolated static func makeStreamRenderBlock(
        ringBuffer: LockFreeRingBuffer,
        silenceGate: ManagedAtomic<UInt8>
    ) -> AVAudioSourceNodeRenderBlock {
        { isSilence, _, frameCount, outputData in
            let ablPointer = UnsafeMutableAudioBufferListPointer(outputData)
            guard ablPointer.count == 1,
                  let firstBuffer = ablPointer.first,
                  firstBuffer.mNumberChannels == 2,
                  let data = firstBuffer.mData else {
                isSilence.pointee = ObjCBool(true)
                return noErr
            }

            let floatPtr = data.assumingMemoryBound(to: Float.self)
            let channelCount = Int(firstBuffer.mNumberChannels)
            let frames = Int(frameCount)

            if silenceGate.load(ordering: .acquiring) != 0 {
                memset(floatPtr, 0, frames * channelCount * MemoryLayout<Float>.size)
                isSilence.pointee = ObjCBool(true)
                return noErr
            }

            // Mid-stream rebuffering: emit silence without attempting a read
            // until the decode side has refilled the ring past its rebuffer
            // threshold. Pattern matches MPV's cache-pause / VLC's rebuffer.
            if ringBuffer.isRebuffering {
                memset(floatPtr, 0, frames * channelCount * MemoryLayout<Float>.size)
                isSilence.pointee = ObjCBool(true)
                return noErr
            }

            let framesRead = ringBuffer.read(into: floatPtr, frameCount: frames)

            if framesRead < frames {
                let remainingSamples = (frames - framesRead) * channelCount
                let offset = framesRead * channelCount
                memset(floatPtr + offset, 0, remainingSamples * MemoryLayout<Float>.size)
            }

            // A complete underrun mid-playback enters the rebuffer state. The
            // decode side will clear it once the ring is refilled. Partial
            // underruns (got some frames, not enough) stay on the existing
            // zero-fill-the-tail path — those are normal jitter at the
            // sub-buffer-size scale and don't justify pausing output.
            if framesRead == 0 {
                ringBuffer.setRebuffering(true)
            }

            isSilence.pointee = ObjCBool(framesRead == 0)
            return noErr
        }
    }

    /// Enters rebuffering, as a dry read in the render block does, unless the
    /// ring holds `minimumFrames`. The decoder clears the flag only when it
    /// writes, so a flag left set over a full ring stalls playback.
    nonisolated static func reportStarvation(of ring: LockFreeRingBuffer, below minimumFrames: Int) {
        guard !ring.isRebuffering, ring.availableFrames < minimumFrames else { return }
        ring.setRebuffering(true)
        // Audio may have landed between the check and the store.
        if ring.availableFrames >= minimumFrames {
            ring.setRebuffering(false)
        }
    }

    #if DEBUG
    /// Test seam: same render block, exposed without widening production visibility.
    internal nonisolated static func makeStreamRenderBlockForTesting(
        ringBuffer: LockFreeRingBuffer,
        silenceGate: ManagedAtomic<UInt8>
    ) -> AVAudioSourceNodeRenderBlock {
        makeStreamRenderBlock(ringBuffer: ringBuffer, silenceGate: silenceGate)
    }
    #endif

    /// Activate the stream bridge: wire AVAudioSourceNode into the engine graph.
    /// Replaces the playerNode path with streamSourceNode → EQ → mixer → output.
    ///
    /// **Critical constraints:**
    /// - Source node format MUST be interleaved (matches ring buffer layout)
    /// - Graph connection format MUST be non-interleaved (engine internal)
    /// - MUST stop/reset engine before rewiring (avoids -10868)
    /// - MUST verify mixer→output after reset
    func activateStreamBridge(ringBuffer: LockFreeRingBuffer, sampleRate: Float64) {
        guard !isBridgeActive else { return }

        spatialOutput.suspendFeed()
        streamRingBuffer = ringBuffer
        streamSampleRate = sampleRate

        // Allocate gate before the render block captures it; lifetime ends in deactivateStreamBridge.
        let gate = ManagedAtomic<UInt8>(0)
        streamSilenceGate = gate

        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: true
        )!

        let renderBlock = Self.makeStreamRenderBlock(ringBuffer: ringBuffer, silenceGate: gate)
        let sourceNode = AVAudioSourceNode(format: sourceFormat, renderBlock: renderBlock)
        streamSourceNode = sourceNode

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.reset()
        }
        // `reset()` can clear manual rendering.
        ensureManualRendering()

        audioEngine.disconnectNodeOutput(playerNode)
        audioEngine.disconnectNodeOutput(eqNode)
        audioEngine.attach(sourceNode)

        let graphFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: audioEngine.outputNode.inputFormat(forBus: 0).sampleRate,
            channels: 2,
            interleaved: false
        )

        audioEngine.connect(sourceNode, to: eqNode, format: graphFormat)
        audioEngine.connect(eqNode, to: audioEngine.mainMixerNode, format: graphFormat)

        if audioEngine.outputConnectionPoints(for: audioEngine.mainMixerNode, outputBus: 0).isEmpty {
            audioEngine.connect(audioEngine.mainMixerNode, to: audioEngine.outputNode, format: nil)
        }

        audioEngine.prepare()
        guard startEngineIfNeeded() else {
            audioEngine.disconnectNodeOutput(sourceNode)
            audioEngine.detach(sourceNode)
            streamSourceNode = nil
            streamRingBuffer = nil
            streamSilenceGate = nil
            AppLog.error(.audio, "AudioEngineController: Stream bridge activation aborted — engine failed to start")
            return
        }
        installVisualizerTapIfNeeded()

        // The engine renders only when the output pulls it.
        spatialOutput.setSourceAvailability {
            ringBuffer.isRebuffering ? 0 : Double(ringBuffer.availableFrames) / sampleRate
        } onStarved: { seconds in
            Self.reportStarvation(of: ringBuffer, below: Int(seconds * sampleRate))
        }
        spatialOutput.reanchor(toSeconds: 0)
        spatialOutput.play()

        isBridgeActive = true
        onBridgeStateChanged?(true)
        AppLog.info(.audio, "AudioEngineController: Stream bridge activated — \(sampleRate)Hz")
    }

    /// Deactivate the stream bridge — detach stream node, reset engine.
    /// Idempotent — safe to call when bridge is not active.
    func deactivateStreamBridge() {
        guard isBridgeActive else { return }

        spatialOutput.suspendFeed()
        spatialOutput.stop()
        spatialOutput.setSourceAvailability(nil)
        audioEngine.stop()
        removeVisualizerTapIfNeeded()

        if let sourceNode = streamSourceNode {
            audioEngine.detach(sourceNode)
        }

        audioEngine.disconnectNodeInput(eqNode, bus: 0)
        audioEngine.disconnectNodeOutput(playerNode)
        audioEngine.disconnectNodeOutput(eqNode)

        let graphFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: audioEngine.outputNode.inputFormat(forBus: 0).sampleRate,
            channels: 2,
            interleaved: false
        )!
        audioEngine.connect(playerNode, to: eqNode, format: graphFormat)
        audioEngine.connect(eqNode, to: audioEngine.mainMixerNode, format: graphFormat)

        if audioEngine.outputConnectionPoints(for: audioEngine.mainMixerNode, outputBus: 0).isEmpty {
            audioEngine.connect(audioEngine.mainMixerNode, to: audioEngine.outputNode, format: nil)
        }

        audioEngine.prepare()

        streamSourceNode = nil
        streamRingBuffer = nil
        streamSilenceGate = nil
        isBridgeActive = false
        onBridgeStateChanged?(false)

        AppLog.info(.audio, "AudioEngineController: Stream bridge deactivated")
    }

    // MARK: - File Loading

    /// Load an audio file for playback. Rewires the engine graph.
    func loadFile(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        rewireForFile(file)
    }

    /// Clear the loaded audio file (used by eject).
    func clearFile() {
        audioFile = nil
    }

    // MARK: - Engine Configuration Change Handlers

    /// Invoked at burst start by `configObserver.onWillReconfigure`. Captures a
    /// snapshot of pre-rewire state and forwards it to AudioPlayer so seek guards
    /// can be armed before the engine restart fires a stale playerNode completion.
    ///
    /// **Caller note:** the system posts AVAudioEngineConfigurationChange *after*
    /// auto-stopping the engine, so by the time this runs `playerNode.isPlaying`
    /// is false and `lastRenderTime` is nil. The `wasPlaying` / `currentTime`
    /// fields below are therefore best-effort placeholders — AudioPlayer
    /// overrides them with its own authoritative state in
    /// `handleEngineWillReconfigure`. The bridge flags are MacAmp-owned and
    /// remain accurate.
    private func handleEngineWillReconfigure() {
        let snapshot = PreReconfigureSnapshot(
            wasPlaying: playerNode.isPlaying,
            wasPaused: false,
            currentTime: readPlayerNodeCurrentTime() ?? 0,
            wasStreamBridge: isBridgeActive
        )
        onEngineWillReconfigure?(snapshot)
    }

    /// Invoked once at burst end by `configObserver.onDidReconfigure` (150 ms
    /// quiet window). The system has auto-reconfigured the output to the new
    /// route and stopped the engine; we refresh format-dependent connections,
    /// verify mixer→output, restart the engine, and notify AudioPlayer to
    /// re-apply transient state and resume playback.
    private func handleEngineDidReconfigure() {
        // 1. Refresh stream bridge graph format if active. The graph format
        //    captured at activate time references the old output sample rate;
        //    re-establishing with the current outputNode format avoids
        //    AVAudioEngine's silent format-conversion overhead.
        if isBridgeActive, let sourceNode = streamSourceNode {
            audioEngine.disconnectNodeOutput(sourceNode)
            audioEngine.disconnectNodeOutput(eqNode)
            let graphFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: audioEngine.outputNode.inputFormat(forBus: 0).sampleRate,
                channels: 2,
                interleaved: false
            )!
            audioEngine.connect(sourceNode, to: eqNode, format: graphFormat)
            audioEngine.connect(eqNode, to: audioEngine.mainMixerNode, format: graphFormat)
        }

        // 2. Video audio plays through AVPlayer outside this graph; nothing to refresh.

        // 3. Verify mixer → output connection survived the reconfigure.
        if audioEngine.outputConnectionPoints(for: audioEngine.mainMixerNode, outputBus: 0).isEmpty {
            audioEngine.connect(audioEngine.mainMixerNode, to: audioEngine.outputNode, format: nil)
        }

        // 4. Restart engine (system stopped it during reconfigure).
        audioEngine.prepare()
        _ = startEngineIfNeeded()

        // 5. Notify AudioPlayer to re-apply volume/balance and resume.
        onEngineDidReconfigure?()
    }

    /// Best-effort snapshot of player-node playback time, mirroring the
    /// computation in `startProgressTimer`. Returns nil during the brief
    /// post-restart window where `lastRenderTime` is not yet populated.
    private func readPlayerNodeCurrentTime() -> Double? {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return nil
        }
        return Double(playerTime.sampleTime) / playerTime.sampleRate + playheadOffset
    }

    // MARK: - Engine State

    /// Whether the audio engine is currently running.
    var isEngineRunning: Bool { audioEngine.isRunning }
}
