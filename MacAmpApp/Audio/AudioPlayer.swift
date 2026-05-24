// swiftlint:disable file_length
import Foundation
import AVFoundation
import Observation
import os

@Observable
@MainActor
final class AudioPlayer { // swiftlint:disable:this type_body_length
    private enum Keys {
        static let volume = "volume"
        static let balance = "balance"
    }

    // MARK: - Engine Controller (owns AVAudioEngine, playerNode, graph wiring, stream bridge)
    @ObservationIgnored private var engine: AudioEngineController!

    // MARK: - Extracted Controllers
    private let equalizer = EqualizerController()
    private let visualizerPipeline = VisualizerPipeline()

    /// Legacy toggle - derives from AppSettings.visualizerMode (forwarded to pipeline)
    var useSpectrumVisualizer: Bool {
        get { AppSettings.instance().visualizerMode == .spectrum }
        set {
            AppSettings.instance().visualizerMode = newValue ? .spectrum : .none
            visualizerPipeline.useSpectrum = newValue
        }
    }

    /// Visualizer smoothing (forwarded to pipeline)
    var visualizerSmoothing: Float {
        get { visualizerPipeline.smoothing }
        set { visualizerPipeline.smoothing = newValue }
    }

    /// Visualizer peak falloff (forwarded to pipeline)
    var visualizerPeakFalloff: Float {
        get { visualizerPipeline.peakFalloff }
        set { visualizerPipeline.peakFalloff = newValue }
    }

    // MARK: - Playback State

    private(set) var playbackState: PlaybackState = .idle
    private(set) var isPlaying: Bool = false
    private(set) var isPaused: Bool = false
    @ObservationIgnored private var currentSeekID: UUID = UUID()
    @ObservationIgnored private var isHandlingCompletion = false
    @ObservationIgnored private var seekGuardActive = false
    @ObservationIgnored private var playlistGeneration: UInt64 = 0

    /// CUE slices currently covered by a single scheduled segment, in playback order.
    /// The scheduled segment spans from `runSlices.first.cueSlice.startTime` to
    /// `runSlices.last.cueSlice.endTime`, which lets the MP3 / AAC decoder run
    /// uninterrupted across slice boundaries (separate `scheduleSegment` calls
    /// snap to compressed-frame boundaries and lose up to ~26ms of audio per
    /// transition for MP3 — exactly the sub-second cut a "gapless" CUE album
    /// would otherwise suffer). The progress callback compares the engine's
    /// absolute time against each slice's bounds and virtually advances state
    /// when it crosses one, so each slice's seek bar, "now playing", and
    /// `currentTrack` update without touching the player.
    @ObservationIgnored private var runSlices: [Track] = []
    var currentTrackURL: URL?
    var currentTitle: String = "No Track Loaded"
    var currentDuration: Double = 0.0
    var currentTime: Double = 0.0
    var playbackProgress: Double = 0.0

    // MARK: - Stream Bridge State (observable, updated via engine callback)
    private(set) var isBridgeActive: Bool = false

    /// True when the audio engine is running AND producing audio output.
    var isEngineRendering: Bool { engine.isEngineRunning && (isPlaying || isBridgeActive) }

    /// Audio volume (0.0-1.0 linear amplitude).
    ///
    /// Persistence is **call-site-driven** — call `commitVolumeToDefaults()`
    /// (or `PlaybackCoordinator.commitVolume()`) at gesture-end. The setter
    /// only propagates to audio backends; writing `UserDefaults` per gesture
    /// tick was shown to starve the main thread (mwvi Phase 0, Mechanism B).
    var volume: Float = 0.75 {
        didSet {
            engine?.setVolume(volume)
            videoPlaybackController.volume = volume
        }
    }
    /// Audio balance (-1.0 left to 1.0 right).
    ///
    /// Persistence is call-site-driven — see `commitBalanceToDefaults()` /
    /// `PlaybackCoordinator.commitBalance()`.
    var balance: Float = 0.0 {
        didSet {
            engine?.setBalance(balance)
        }
    }

    /// Commit the current `volume` to `UserDefaults`.
    /// Approved callers (plan §6.1): `PlaybackCoordinator.commitVolume()`.
    internal func commitVolumeToDefaults() {
        UserDefaults.standard.set(volume, forKey: Keys.volume)
    }

    /// Commit the current `balance` to `UserDefaults`.
    /// Approved callers (plan §6.1, mirrored per todo 1B.9):
    /// `PlaybackCoordinator.commitBalance()`.
    internal func commitBalanceToDefaults() {
        UserDefaults.standard.set(balance, forKey: Keys.balance)
    }

    // MARK: - Playlist (extracted to PlaylistController)

    let playlistController = PlaylistController()
    var playlist: [Track] { playlistController.playlist }
    var playlistPosition: Int? { playlistController.currentPosition }
    var playlistCount: Int { playlistController.count }
    var currentTrack: Track?
    var onTrackMetadataUpdate: ((Track) -> Void)?
    var onPlaylistAdvanceRequest: ((Track) -> Void)?
    var onPlaybackFinished: (() -> Void)?
    var shuffleEnabled: Bool {
        get { playlistController.shuffleEnabled }
        set { playlistController.shuffleEnabled = newValue }
    }

    // MARK: - Video (extracted to VideoPlaybackController)

    let videoPlaybackController = VideoPlaybackController()
    var currentMediaType: MediaType = .audio
    var videoPlayer: AVPlayer? { videoPlaybackController.player }
    var videoMetadataString: String { videoPlaybackController.metadataString }

    enum MediaType {
        case audio
        case video
    }

    /// Repeat mode (Winamp 5 Modern: off/all/one with "1" badge)
    var repeatMode: AppSettings.RepeatMode {
        get { AppSettings.instance().repeatMode }
        set { AppSettings.instance().repeatMode = newValue }
    }

    // MARK: - Equalizer Forwarding

    var preamp: Float {
        get { equalizer.preamp }
        set { equalizer.preamp = newValue }
    }
    var eqBands: [Float] {
        get { equalizer.eqBands }
        set { equalizer.eqBands = newValue }
    }
    var isEqOn: Bool {
        get { equalizer.isEqOn }
        set { equalizer.isEqOn = newValue }
    }
    var eqAutoEnabled: Bool {
        get { equalizer.eqAutoEnabled }
        set { equalizer.eqAutoEnabled = newValue }
    }
    var useLogScaleBands: Bool {
        get { equalizer.useLogScaleBands }
        set { equalizer.useLogScaleBands = newValue }
    }
    var eqPresetStore: EQPresetStore { equalizer.eqPresetStore }
    var userPresets: [EQPreset] { equalizer.userPresets }
    var visualizerLevels: [Float] { visualizerPipeline.levels }
    var appliedAutoPresetTrack: String? {
        get { equalizer.appliedAutoPresetTrack }
        set { equalizer.appliedAutoPresetTrack = newValue }
    }
    var channelCount: Int = 2
    var bitrate: Int = 0
    var sampleRate: Int = 0

    // MARK: - Init / Deinit

    init() {
        if let saved = UserDefaults.standard.object(forKey: Keys.volume) as? Float {
            self.volume = saved
        }
        if let saved = UserDefaults.standard.object(forKey: Keys.balance) as? Float {
            self.balance = saved
        }

        engine = AudioEngineController(eqNode: equalizer.eqNode, visualizerPipeline: visualizerPipeline)

        // Wire engine callbacks
        engine.onProgressUpdate = { [weak self] currentTime, progress in
            guard let self else { return }
            if self.currentTrack?.cueSlice != nil {
                // Virtual slice transition: the engine is playing one segment that
                // spans the whole run, so progress crossing a slice boundary means
                // we've moved to the next slice — advance state without touching
                // the player. Search the run rather than stepping one, so a long
                // tick interval doesn't strand us on a slice we've already passed.
                if let covering = self.sliceCovering(absoluteTime: currentTime),
                   covering.id != self.currentTrack?.id {
                    self.virtualSliceAdvance(to: covering)
                }
                guard let slice = self.currentTrack?.cueSlice else { return }
                let sliceCurrent = max(0, min(currentTime - slice.startTime, slice.duration))
                self.currentTime = sliceCurrent
                self.playbackProgress = slice.duration > 0 ? sliceCurrent / slice.duration : 0
            } else {
                self.currentTime = currentTime
                if self.currentDuration > 0 {
                    self.playbackProgress = progress
                } else {
                    self.playbackProgress = 0
                }
            }
        }
        engine.onPlaybackEnded = { [weak self] seekID in
            self?.onPlaybackEnded(fromSeekID: seekID)
        }
        engine.onBridgeStateChanged = { [weak self] isActive in
            self?.isBridgeActive = isActive
        }

        // Apply restored volume/balance to engine nodes
        engine.setVolume(volume)
        engine.setBalance(balance)

        // Sync initial visualizer mode
        visualizerPipeline.useSpectrum = AppSettings.instance().visualizerMode == .spectrum

        // Setup video playback callbacks
        videoPlaybackController.onPlaybackEnded = { [weak self] in
            Task { @MainActor in
                self?.onPlaybackEnded()
            }
        }
        videoPlaybackController.onTimeUpdate = { [weak self] time, duration, progress in
            guard let self else { return }
            self.currentTime = time
            self.currentDuration = duration
            self.playbackProgress = progress
        }
        videoPlaybackController.volume = volume
    }

    isolated deinit {
        engine.shutdown()
    }

    // MARK: - State Machine

    private func transition(to newState: PlaybackState) {
        guard playbackState != newState else { return }
        playbackState = newState
        switch newState {
        case .playing:
            setDerivedState(isPlaying: true, isPaused: false)
        case .paused:
            setDerivedState(isPlaying: false, isPaused: true)
        default:
            setDerivedState(isPlaying: false, isPaused: false)
        }
    }

    private func setDerivedState(isPlaying: Bool, isPaused: Bool) {
        if self.isPlaying != isPlaying { self.isPlaying = isPlaying }
        if self.isPaused != isPaused { self.isPaused = isPaused }
    }

    private func shouldIgnoreCompletion(from seekID: UUID?) -> Bool {
        if let seekID, seekID != currentSeekID { return true }
        if seekGuardActive && seekID == nil { return true }
        if case .stopped(let reason) = playbackState,
           reason == .manual || reason == .ejected { return true }
        return false
    }

    // MARK: - Track Management

    func addTrack(url: URL) {
        let normalizedURL = url.standardizedFileURL

        if playlistController.containsTrack(url: normalizedURL) {
            AppLog.debug(.audio, "Track already pending or in playlist: \(normalizedURL.lastPathComponent)")
            return
        }

        AppLog.debug(.audio, "Adding track from \(normalizedURL.lastPathComponent)")
        playlistController.addPendingURL(normalizedURL)

        let placeholder = Track(
            url: normalizedURL,
            title: normalizedURL.lastPathComponent,
            artist: "Loading...",
            duration: 0.0
        )

        playlistController.addPlaceholder(placeholder)

        let generation = playlistGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.playlistController.removePendingURL(normalizedURL) }

            AppLog.debug(.audio, "Loading metadata for \(normalizedURL.lastPathComponent)")
            let metadata = await MetadataLoader.loadTrackMetadata(from: normalizedURL)

            // Reject stale metadata if playlist was cleared/replaced while loading
            guard self.playlistGeneration == generation else {
                AppLog.debug(.audio, "Discarding stale metadata for \(normalizedURL.lastPathComponent) — playlist changed")
                return
            }

            let track = Track(url: normalizedURL, title: metadata.title, artist: metadata.artist, duration: metadata.duration)
            AppLog.debug(.audio, "Metadata loaded - title: '\(track.title)', artist: '\(track.artist)', duration: \(track.duration)s")

            if self.playlistController.replacePlaceholder(id: placeholder.id, with: track) {
                if self.currentTrack?.id == placeholder.id {
                    AppLog.debug(.audio, "Updating current track metadata")
                    self.currentTrack = track
                    self.currentTitle = "\(track.title) - \(track.artist)"
                    // Don't overwrite currentDuration from metadata (AVAsset.duration)
                    // when the engine has the current audio file loaded. Engine file
                    // duration is the authoritative runtime source — metadata duration
                    // can diverge on VBR/compressed files, causing seek bar drift.
                    // Use metadata duration only for non-audio or before file loads.
                    if self.currentMediaType != .audio || self.engine.currentFileDuration <= 0 {
                        self.currentDuration = track.duration
                    }
                    self.currentTrackURL = track.url
                    self.onTrackMetadataUpdate?(track)
                }
            } else if !self.playlistController.containsTrack(url: normalizedURL) {
                self.playlistController.addTrack(track)
            }
        }
    }

    func addStreamTrack(_ track: Track) {
        playlistController.addTrack(track)
    }

    /// Add the tracks parsed from a CUE sheet directly to the playlist, bypassing
    /// the async metadata-load placeholder mechanism used for whole-file adds.
    /// Skips the add if the playlist already contains entries from the same sheet.
    /// - Returns: true if tracks were added, false if the sheet was already present.
    @discardableResult
    func addCueTracks(_ tracks: [Track]) -> Bool {
        guard let sheetURL = tracks.first?.cueSlice?.cueSheetURL else { return false }
        if playlistController.containsCueSheet(url: sheetURL) {
            AppLog.debug(.audio, "CUE sheet already in playlist, skipping: \(sheetURL.lastPathComponent)")
            return false
        }
        for track in tracks {
            playlistController.addTrack(track)
        }
        return true
    }

    func removeTrack(at index: Int) {
        let removedID: UUID? = playlistController.playlist.indices.contains(index)
            ? playlistController.playlist[index].id
            : nil
        let removedIsInRun = removedID != nil && runSlices.contains { $0.id == removedID }
        playlistController.removeTrack(at: index)
        // If the removed slice was part of the current scheduled run, the engine
        // segment still spans through its data and would play the just-removed
        // audio. Re-seek to the current position to rebuild the run from the new
        // playlist; this is a brief gap on removal, but the alternative is the
        // user hearing what they just deleted. Removals outside the run leave the
        // run valid — Track ids are stable, so the runSlices array still resolves
        // to the same audio independent of playlist-index shifts.
        if removedIsInRun, let current = currentTrack, current.isCueSlice,
           isPlaying || isPaused, engine.audioFile != nil {
            seek(to: currentTime, resume: isPlaying)
        }
    }

    func replacePlaylist(with tracks: [Track]) {
        playlistGeneration &+= 1
        playlistController.clear()
        for track in tracks { playlistController.addTrack(track) }
        runSlices = []
        AppLog.debug(.audio, "Replaced playlist with \(tracks.count) tracks")
    }

    func clearPlaylist() {
        playlistGeneration &+= 1
        playlistController.clear()
        runSlices = []
    }

    func playTrack(track: Track) {
        guard !track.isStream else {
            AppLog.error(.audio, "Cannot play internet radio streams. Stream URL: \(track.url). Use PlaybackCoordinator to route streams to StreamPlayer.")
            return
        }

        updatePlaylistPosition(with: track)

        currentSeekID = UUID()
        seekGuardActive = true

        engine.stopAudio()
        engine.invalidateProgressTimer()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            self.seekGuardActive = false
        }

        currentTrack = track
        currentTitle = "\(track.title) - \(track.artist)"
        currentDuration = track.duration
        currentTrackURL = track.url
        currentTime = 0
        playbackProgress = 0
        transition(to: .preparing)
        seekGuardActive = false
        playlistController.resetEnded()

        AppLog.info(.audio, "Playing track '\(track.title)'")

        let mediaType = detectMediaType(url: track.url)

        if currentMediaType != mediaType {
            if currentMediaType == .video {
                videoPlaybackController.cleanup()
                AppLog.debug(.audio, "Switching from video to audio - cleanup complete")
            } else if currentMediaType == .audio {
                engine.removeVisualizerTapIfNeeded()
                AppLog.debug(.audio, "Switching from audio to video - tap removed")
            }
        }

        currentMediaType = mediaType

        switch mediaType {
        case .audio:
            loadAudioFile(for: track)
        case .video:
            videoPlaybackController.loadVideo(url: track.url, autoPlay: false)
            transition(to: .playing)
        }

        if equalizer.eqAutoEnabled {
            equalizer.applyAutoPreset(for: track)
        }

        play()
    }

    private func detectMediaType(url: URL) -> MediaType {
        let videoExtensions = ["mp4", "mov", "m4v", "avi"]
        return videoExtensions.contains(url.pathExtension.lowercased()) ? .video : .audio
    }

    private func loadAudioFile(for track: Track) {
        do {
            let normalizedTrackURL = track.url.standardizedFileURL
            let loadedURL = engine.currentFileURL?.standardizedFileURL
            let canReuseLoadedFile = track.isCueSlice
                && loadedURL == normalizedTrackURL
                && engine.audioFile != nil

            if !canReuseLoadedFile {
                try engine.loadFile(url: track.url)
            }

            currentSeekID = UUID()
            if let slice = track.cueSlice {
                // Schedule the whole run of consecutive same-file slices as ONE segment.
                // This keeps the decoder running across slice boundaries (separate
                // scheduleSegment calls would each re-prime the MP3 decoder, eating
                // ~26ms of audio at every transition). Slice-level state updates
                // happen in the progress callback.
                runSlices = computeRunSlices(startingAt: track)
                let runEndTime = runSlices.last?.cueSlice?.endTime ?? slice.endTime
                _ = engine.scheduleFrom(
                    time: slice.startTime,
                    endTime: runEndTime,
                    seekID: currentSeekID
                )
            } else {
                runSlices = []
                _ = engine.scheduleFrom(time: 0, seekID: currentSeekID)
            }
            engine.setVolume(volume)
            engine.setBalance(balance)

            // For non-CUE tracks, sync currentDuration from the loaded file.
            // For CUE slices, currentDuration was already set from track.duration (slice length)
            // in playTrack and must not be overwritten with the file duration.
            if !track.isCueSlice {
                let fileDuration = engine.currentFileDuration
                if fileDuration.isFinite && fileDuration > 0 {
                    currentDuration = fileDuration
                }
            }

            Task { @MainActor [weak self] in
                if let props = await MetadataLoader.loadAudioProperties(from: track.url) {
                    self?.channelCount = props.channelCount
                    self?.bitrate = props.bitrate
                    self?.sampleRate = props.sampleRate
                }
            }
        } catch {
            AppLog.error(.audio, "Failed to open file: \(error)")
            engine.clearFile()
            transition(to: .stopped(.manual))
        }
    }

    /// Walk the playlist forward from `start` collecting every consecutive same-file
    /// CUE slice whose `cueSlice.startTime` equals the previous slice's `endTime`.
    /// The result is the run of slices a single `scheduleSegment` call covers so the
    /// decoder runs uninterrupted. Stops at: shuffle / repeat-one (where "next" is
    /// not the sequentially-next track), a non-CUE track, a different-file slice,
    /// a non-contiguous slice, or end of playlist (without wrapping for repeat-all
    /// to avoid an unbounded run).
    private func computeRunSlices(startingAt start: Track) -> [Track] {
        guard start.isCueSlice else { return [] }
        let playlist = playlistController.playlist
        guard let startIdx = playlist.firstIndex(of: start) else { return [start] }
        if playlistController.shuffleEnabled || playlistController.repeatMode == .one {
            return [start]
        }
        var run: [Track] = [start]
        let runURL = start.url.standardizedFileURL
        var idx = startIdx
        while idx + 1 < playlist.count {
            idx += 1
            let candidate = playlist[idx]
            guard let candidateSlice = candidate.cueSlice,
                  candidate.url.standardizedFileURL == runURL,
                  let lastSlice = run.last?.cueSlice,
                  abs(candidateSlice.startTime - lastSlice.endTime) < 0.001 else {
                break
            }
            run.append(candidate)
        }
        return run
    }

    /// Find the slice in the current run whose `[startTime, endTime)` contains
    /// the engine's absolute file time. Returns nil when `absoluteTime` is outside
    /// every slice in the run (e.g., transient tail past the run end before the
    /// completion handler fires).
    private func sliceCovering(absoluteTime: Double) -> Track? {
        runSlices.first(where: { track in
            guard let slice = track.cueSlice else { return false }
            return absoluteTime >= slice.startTime && absoluteTime < slice.endTime
        })
    }

    /// Advance observable state to a slice that the engine is already playing as
    /// part of the current run. No engine interaction — the audio has not been
    /// stopped or rescheduled, only our bookkeeping has caught up to it.
    private func virtualSliceAdvance(to track: Track) {
        playlistController.updatePosition(with: track)
        currentTrack = track
        currentTitle = "\(track.artist) - \(track.title)"
        currentDuration = track.duration
        currentTrackURL = track.url
        playlistController.resetEnded()
        onPlaylistAdvanceRequest?(track)
    }

    // MARK: - Transport

    func play() {
        if playlistController.hasEnded && !playlist.isEmpty {
            playTrack(track: playlist[0])
            return
        }

        if currentMediaType == .video {
            videoPlaybackController.play()
            transition(to: .playing)
            AppLog.debug(.audio, "Play (Video)")
            return
        }

        guard engine.audioFile != nil else {
            AppLog.warn(.audio, "No track loaded to play.")
            return
        }

        let fileDuration = engine.currentFileDuration
        if currentTime >= fileDuration - 0.01 {
            onPlaybackEnded()
            return
        }

        guard engine.startEngineIfNeeded() else {
            AppLog.error(.audio, "Play aborted — engine failed to start")
            return
        }

        engine.installVisualizerTapIfNeeded()
        engine.playAudio()
        engine.startProgressTimer()
        transition(to: .playing)
        seekGuardActive = false
        AppLog.debug(.audio, "Play")
    }

    func pause() {
        if currentMediaType == .video {
            videoPlaybackController.pause()
            transition(to: .paused)
            AppLog.debug(.audio, "Pause (Video)")
            return
        }

        guard engine.isPlayerNodePlaying else { return }
        engine.pauseAudio()
        engine.removeVisualizerTapIfNeeded()
        transition(to: .paused)
        seekGuardActive = false
        AppLog.debug(.audio, "Pause")
    }

    func stop() {
        transition(to: .stopped(.manual))

        if currentMediaType == .video {
            videoPlaybackController.stop()
            currentMediaType = .audio
            AppLog.debug(.audio, "Stop (Video) - cleaned up AVPlayer")
        }

        engine.stopAudio()
        currentSeekID = UUID()
        runSlices = []
        _ = engine.scheduleFrom(time: 0, seekID: currentSeekID)

        currentTrack = nil
        currentTitle = "No Track Loaded"
        currentTrackURL = nil
        currentDuration = 0.0
        currentTime = 0
        playbackProgress = 0
        engine.invalidateProgressTimer()
        engine.removeVisualizerTapIfNeeded()

        bitrate = 0
        sampleRate = 0
        channelCount = 2
        seekGuardActive = false
        AppLog.debug(.audio, "Stop")
    }

    func eject() {
        stop()
        transition(to: .stopped(.ejected))
        playlistGeneration &+= 1
        playlistController.clear()
        currentTrack = nil
        currentTrackURL = nil
        currentTitle = "No Track Loaded"
        currentDuration = 0.0
        currentTime = 0.0
        playbackProgress = 0.0
        appliedAutoPresetTrack = nil
        engine.clearFile()
        bitrate = 0
        sampleRate = 0
        channelCount = 2
        AppLog.info(.audio, "Eject - cleared playlist and reset playback state")
    }

    // MARK: - Equalizer Forwarding (backed by EqualizerController)

    func setPreamp(value: Float) { equalizer.setPreamp(value: value) }
    func setEqBand(index: Int, value: Float) { equalizer.setEqBand(index: index, value: value) }
    func toggleEq(isOn: Bool) { equalizer.toggleEq(isOn: isOn) }
    func applyPreset(_ preset: EqfPreset) { equalizer.applyPreset(preset) }
    func applyEQPreset(_ preset: EQPreset) { equalizer.applyEQPreset(preset) }
    func getCurrentEQPreset(name: String) -> EQPreset { equalizer.getCurrentEQPreset(name: name) }
    func saveUserPreset(named name: String) { equalizer.saveUserPreset(named: name) }
    func deleteUserPreset(id: UUID) { equalizer.deleteUserPreset(id: id) }
    func importEqfPreset(from url: URL) { equalizer.importEqfPreset(from: url) }

    func savePresetForCurrentTrack() {
        guard let t = currentTrack else { return }
        equalizer.savePresetForCurrentTrack(t)
    }

    func setAutoEQEnabled(_ isEnabled: Bool) {
        equalizer.setAutoEQEnabled(isEnabled, currentTrack: currentTrack)
    }

    // MARK: - Stream Bridge Forwarding (backed by AudioEngineController)

    func activateStreamBridge(ringBuffer: LockFreeRingBuffer, sampleRate: Float64) {
        engine.activateStreamBridge(ringBuffer: ringBuffer, sampleRate: sampleRate)
        engine.setVolume(volume)
        engine.setBalance(balance)
    }

    func deactivateStreamBridge() {
        engine.deactivateStreamBridge()
    }

    /// No-op when the stream bridge is inactive.
    func setStreamSilenced(_ silenced: Bool) {
        engine.setStreamSilenced(silenced)
    }

    #if DEBUG
    var isStreamSilenceGateActive: Bool { engine.isStreamSilenceGateActive }
    #endif

    /// The audio IO workgroup from the engine output node.
    /// Valid only while the engine is running (i.e., after bridge activation).
    var audioWorkgroup: os_workgroup_t? {
        engine.audioWorkgroup
    }

    // MARK: - Seeking / Scrubbing

    func seekToPercent(_ percent: Double, resume: Bool? = nil) {
        if currentMediaType == .video {
            videoPlaybackController.seekToPercent(percent, resume: resume, completion: videoSeekCompletion)
            return
        }

        guard engine.audioFile != nil else {
            AppLog.warn(.audio, "seekToPercent: No audio file loaded")
            return
        }

        // For CUE slices, percent is relative to the slice — seek() does the offset mapping.
        let targetTime: Double
        if let slice = currentTrack?.cueSlice {
            targetTime = percent * slice.duration
        } else {
            targetTime = percent * engine.currentFileDuration
        }
        seek(to: targetTime, resume: resume)
    }

    func seek(to time: Double, resume: Bool? = nil) {
        if currentMediaType == .video {
            videoPlaybackController.seek(to: time, resume: resume, completion: videoSeekCompletion)
            return
        }

        guard engine.audioFile != nil else {
            AppLog.warn(.audio, "seek: Cannot seek - no audio file loaded")
            return
        }

        let shouldPlay = resume ?? isPlaying
        seekGuardActive = true
        currentSeekID = UUID()
        engine.invalidateProgressTimer()

        // For CUE slices, `time` is slice-relative; translate to absolute file time
        // and bound the scheduled segment to the END of the current run, not just
        // the current slice. Bounding to slice.endTime would split the single-segment
        // run on every seek and cost the gapless property until the next track change.
        // Recompute the run against the current playlist — anything that changed it
        // (track removal, shuffle/repeat toggle) needs to flow into the new bound.
        let absoluteTime: Double
        let scheduleEndTime: Double?
        let targetProgress: Double
        let sliceRelativeTime: Double
        if let current = currentTrack, let slice = current.cueSlice {
            runSlices = computeRunSlices(startingAt: current)
            let clampedInSlice = max(0, min(time, slice.duration))
            absoluteTime = slice.startTime + clampedInSlice
            scheduleEndTime = runSlices.last?.cueSlice?.endTime ?? slice.endTime
            targetProgress = slice.duration > 0 ? clampedInSlice / slice.duration : 0
            sliceRelativeTime = clampedInSlice
        } else {
            let fileDuration = engine.currentFileDuration
            absoluteTime = time
            scheduleEndTime = nil
            targetProgress = fileDuration > 0 ? time / fileDuration : 0
            sliceRelativeTime = time
        }

        let audioScheduled = engine.scheduleFrom(
            time: absoluteTime,
            endTime: scheduleEndTime,
            seekID: currentSeekID
        )

        currentTime = sliceRelativeTime
        playbackProgress = targetProgress

        if audioScheduled && shouldPlay {
            engine.startEngineIfNeeded()
            engine.installVisualizerTapIfNeeded()
            engine.playAudio()
            engine.startProgressTimer()
            transition(to: .playing)
        } else if !audioScheduled {
            transition(to: .stopped(.completed))
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                self?.onPlaybackEnded()
            }
        } else {
            transition(to: .paused)
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self?.seekGuardActive = false
        }
    }

    /// Shared completion handler for video seek operations.
    /// Syncs video playback state back to AudioPlayer after AVPlayer seek completes.
    private var videoSeekCompletion: @Sendable (Double) -> Void {
        { [weak self] (actualTime: Double) in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = actualTime
                self.playbackProgress = self.videoPlaybackController.progress
                self.currentDuration = self.videoPlaybackController.duration
                self.transition(to: self.videoPlaybackController.isPlaying ? .playing : .paused)
            }
        }
    }

    // MARK: - Visualizer Forwarding (backed by VisualizerPipeline)

    func getFrequencyData(bands: Int) -> [Float] {
        visualizerPipeline.getFrequencyData(bands: bands, isPlaying: isEngineRendering)
    }

    func getWaveformSamples(count: Int) -> [Float] {
        visualizerPipeline.getWaveformSamples(count: count)
    }

    func snapshotButterchurnFrame() -> ButterchurnFrame? {
        guard currentMediaType == .audio && isEngineRendering else { return nil }
        return visualizerPipeline.snapshotButterchurnFrame()
    }

    // MARK: - Playback Completion

    private func onPlaybackEnded(fromSeekID: UUID? = nil) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard !self.isHandlingCompletion else { return }

            if self.shouldIgnoreCompletion(from: fromSeekID) { return }

            self.isHandlingCompletion = true
            // The scheduled segment can span an entire run of consecutive same-file
            // CUE slices, so when it completes we want to advance past the WHOLE run,
            // not into the next slice within it. Snap currentTrack to the last slice
            // in the run before computing the next track — the 0.1s progress timer
            // may not have caught up to it yet at the moment completion fires.
            if let lastInRun = self.runSlices.last,
               self.currentTrack?.id != lastInRun.id {
                self.virtualSliceAdvance(to: lastInRun)
            }
            self.runSlices = []
            self.transition(to: .stopped(.completed))
            self.engine.invalidateProgressTimer()
            self.playbackProgress = 1
            // CUE slices end at slice.duration (slice-relative). Non-CUE audio uses the
            // engine's file duration (authoritative). Video falls back to currentDuration.
            if let slice = self.currentTrack?.cueSlice {
                self.currentTime = slice.duration
            } else if self.currentMediaType == .audio, self.engine.currentFileDuration > 0 {
                self.currentTime = self.engine.currentFileDuration
            } else {
                self.currentTime = self.currentDuration
            }
            let action = self.nextTrack()
            switch action {
            case .requestCoordinatorPlayback(let track), .playLocally(let track):
                self.onPlaylistAdvanceRequest?(track)
            case .none:
                self.onPlaybackFinished?()
            default:
                break
            }
            if !self.isPlaying {
                self.engine.removeVisualizerTapIfNeeded()
            }
            self.seekGuardActive = false

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                self.isHandlingCompletion = false
            }
        }
    }

    // MARK: - Playlist Navigation

    enum PlaylistAdvanceAction {
        case none
        case restartCurrent
        case playLocally(Track)
        case requestCoordinatorPlayback(Track)
    }

    func updatePlaylistPosition(with track: Track?) {
        playlistController.updatePosition(with: track)
    }

    @discardableResult
    func nextTrack(isManualSkip: Bool = false) -> PlaylistAdvanceAction {
        playlistController.updatePosition(with: currentTrack)
        let action = playlistController.nextTrack(isManualSkip: isManualSkip)
        return handlePlaylistAction(action)
    }

    @discardableResult
    func nextTrack(from track: Track?, isManualSkip: Bool = false) -> PlaylistAdvanceAction {
        let action = playlistController.nextTrack(from: track, isManualSkip: isManualSkip)
        return handlePlaylistAction(action)
    }

    @discardableResult
    func previousTrack() -> PlaylistAdvanceAction {
        playlistController.updatePosition(with: currentTrack)
        let action = playlistController.previousTrack()
        return handlePlaylistAction(action)
    }

    @discardableResult
    func previousTrack(from track: Track?) -> PlaylistAdvanceAction {
        let action = playlistController.previousTrack(from: track)
        return handlePlaylistAction(action)
    }

    private func handlePlaylistAction(_ action: PlaylistController.AdvanceAction) -> PlaylistAdvanceAction {
        switch action {
        case .none:
            return .none
        case .restartCurrent:
            seek(to: 0, resume: true)
            return .restartCurrent
        case .playTrack(let track):
            playTrack(track: track)
            return .playLocally(track)
        case .requestCoordinatorPlayback(let track):
            return .requestCoordinatorPlayback(track)
        case .endOfPlaylist:
            return .none
        }
    }
}
