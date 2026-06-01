import Foundation
import MediaPlayer
import Observation

/// Coordinates playback between local files (AudioPlayer) and internet radio streams (StreamPlayer).
///
/// This coordinator prevents both backends from playing simultaneously, which would cause audio chaos.
/// It provides a unified API for the UI to play content regardless of source type.
///
/// **Architecture:**
/// - Local files (.mp3, .flac, etc.) → AudioPlayer (AVAudioPlayerNode) with 10-band EQ
/// - Internet radio (http://, https://) → StreamPlayer (custom decode pipeline) → AudioPlayer stream bridge (AVAudioSourceNode) with EQ + visualization
///
/// **Usage:**
/// ```swift
/// // Play a track from the playlist
/// await coordinator.play(track: myTrack)
///
/// // Play a radio station
/// await coordinator.play(station: myStation)
///
/// // Unified controls
/// coordinator.pause()
/// coordinator.stop()
/// coordinator.togglePlayPause()
/// ```
///
/// **State Queries:**
/// - `streamTitle` - Current track/stream title
/// - `streamArtist` - Stream artist (radio only)
/// - `isBuffering` - Buffering state (radio only)
/// - `error` - Error message if playback failed
@MainActor
@Observable
final class PlaybackCoordinator {
    // MARK: - Dependencies

    private let audioPlayer: AudioPlayer       // Local files with EQ
    private let streamPlayer: StreamPlayer     // Internet radio

    // MARK: - Unified State

    /// Derived from the active audio source. True when audio is actively rendering to speakers.
    /// During stream buffering stalls, this returns false (audio is not being rendered).
    var isPlaying: Bool {
        switch currentSource {
        case .localTrack: return audioPlayer.isPlaying
        case .radioStation: return streamPlayer.isPlaying && !streamPlayer.isBuffering
        case .none: return false
        }
    }

    /// Derived from the active audio source. True when user has explicitly paused playback.
    /// False during buffering stalls (not user-initiated) and error states.
    var isPaused: Bool {
        switch currentSource {
        case .localTrack: return audioPlayer.isPaused
        case .radioStation:
            return !streamPlayer.isPlaying && !streamPlayer.isBuffering && streamPlayer.error == nil
        case .none: return false
        }
    }

    private(set) var currentSource: PlaybackSource?
    private(set) var currentTitle: String?
    private(set) var currentTrack: Track?  // For playlist position tracking

    /// Cover art for the current local file, surfaced to the system Now Playing
    /// center. Resolved asynchronously at track start; `nil` for streams, while
    /// resolution is in flight, or when no artwork is found.
    private var currentArtwork: MPMediaItemArtwork?

    /// Generation token for in-flight artwork resolution. Bumped on every track
    /// change so a slow resolve for a previous track cannot overwrite the current one.
    private var artworkRequestID = 0

    enum PlaybackSource {
        case localTrack(URL)
        case radioStation(RadioStation)
    }

    // MARK: - Unified Display Time

    /// Elapsed time for display — delegates to the active backend.
    /// Local files: engine progress timer. Streams: anchor-based elapsed counter.
    var displayTime: Double {
        switch currentSource {
        case .radioStation: return streamPlayer.elapsedTime
        case .localTrack: return audioPlayer.currentTime
        case nil: return 0
        }
    }

    /// Duration for display — 0 for streams (unknown/infinite).
    var displayDuration: Double {
        switch currentSource {
        case .radioStation: return 0
        case .localTrack: return audioPlayer.currentDuration
        case nil: return 0
        }
    }

    // MARK: - Format Indicators (routed by current source)

    /// Sample rate (Hz) of the currently playing audio.
    /// `0` when nothing is playing or the value isn't known yet.
    var currentSampleRate: Int {
        switch currentSource {
        case .localTrack: return audioPlayer.sampleRate
        case .radioStation: return Int(streamPlayer.currentSampleRate)
        case nil: return 0
        }
    }

    /// Bitrate (bits/second) of the audio currently being rendered. Local
    /// MP3 files report the declared frame-header bitrate of the frame
    /// playing now — steady for CBR, jumping per frame for VBR; HTTP streams
    /// and other local formats report the windowed average over the most
    /// recent `BitrateTracker.windowSeconds`. `0` when nothing is playing.
    var currentBitrate: Int {
        switch currentSource {
        case .localTrack: return audioPlayer.currentBitrate
        case .radioStation: return streamPlayer.currentBitrate
        case nil: return 0
        }
    }

    /// Channel count (1 = mono, 2 = stereo).
    var currentChannelCount: Int {
        switch currentSource {
        case .localTrack: return audioPlayer.channelCount
        case .radioStation: return streamPlayer.currentChannelCount
        case nil: return 0
        }
    }

    // MARK: - Playlist Position

    /// Track position string ("3") — nil when no playlist track is active.
    /// Guards against stale values during non-playlist playback (Oracle finding).
    var trackPositionString: String? {
        guard currentTrack != nil,
              let position = audioPlayer.playlistPosition else { return nil }
        return "\(position)"
    }

    // MARK: - Capability Flags

    /// Whether the stream backend is currently active (playing, paused, or buffering).
    /// Uses `currentSource` rather than `currentTrack?.isStream` because `currentTrack`
    /// can be nil when playing a station directly via `play(station:)`.
    /// Returns false when the stream is in an error state (no audio rendering),
    /// which re-enables EQ/balance controls so the user isn't stuck with dimmed UI.
    private var isStreamBackendActive: Bool {
        guard case .radioStation = currentSource else { return false }
        // Stream in error state is effectively inactive — re-enable controls
        return streamPlayer.error == nil
    }

    /// EQ, balance, and other audio-processing features are available when not streaming,
    /// OR when the stream bridge is active (stream decoded through AVAudioEngine).
    /// Dimmed only during stream error or before bridge activates (prebuffering).
    var supportsAudioProcessing: Bool { !isStreamBackendActive || audioPlayer.isBridgeActive }

    // MARK: - Initialization

    init(audioPlayer: AudioPlayer, streamPlayer: StreamPlayer) {
        self.audioPlayer = audioPlayer
        self.streamPlayer = streamPlayer

        self.audioPlayer.onTrackMetadataUpdate = { [weak self] track in
            guard let self else { return }
            self.updateTrackMetadata(track)
        }

        self.audioPlayer.onPlaylistAdvanceRequest = { [weak self] track in
            guard let self else { return }
            Task { @MainActor in
                await self.handleExternalPlaylistAdvance(track: track)
            }
        }

        // Wire local playback finished (no next track) for Now Playing cleanup.
        // Clear source state to prevent late metadata callbacks from repopulating Now Playing.
        self.audioPlayer.onPlaybackFinished = { [weak self] in
            guard let self else { return }
            self.currentSource = nil
            self.currentTitle = nil
            self.currentTrack = nil
            self.clearNowPlayingInfo()
        }

        // Wire stream pipeline format-ready callback to activate engine bridge
        self.streamPlayer.onFormatReady = { [weak self] sampleRate in
            guard let self,
                  let ringBuffer = self.streamPlayer.currentRingBuffer else { return }
            self.audioPlayer.activateStreamBridge(ringBuffer: ringBuffer, sampleRate: sampleRate)
            // Belt-and-suspenders: a fresh bridge already has gate=0, but be explicit.
            self.audioPlayer.setStreamSilenced(false)

            // Pass the audio IO workgroup to the decode pipeline so its thread
            // shares the real-time scheduling group with the Core Audio IO thread
            self.streamPlayer.setAudioWorkgroup(self.audioPlayer.audioWorkgroup)
        }

        // Wire stream terminal state callback for bridge teardown
        self.streamPlayer.onStreamTerminated = { [weak self] in
            guard let self else { return }
            if self.audioPlayer.isBridgeActive {
                self.audioPlayer.deactivateStreamBridge()
            }
        }

        // Wire stream metadata change callback for Now Playing updates
        self.streamPlayer.onMetadataChanged = { [weak self] in
            guard let self else { return }
            self.updateNowPlayingInfo()
        }

        // Wire stream state change callback for Now Playing playback state updates
        // (buffering → playing → reconnect → error transitions)
        self.streamPlayer.onStreamStateChanged = { [weak self] in
            guard let self else { return }
            self.updateNowPlayingInfo()
        }

        self.streamPlayer.silenceGateForwarder = { [weak self] silenced in
            self?.audioPlayer.setStreamSilenced(silenced)
        }
    }

    // MARK: - Volume & Balance Routing

    /// Routes volume through `AudioPlayer`. The `AudioPlayer.volume.didSet`
    /// handles propagation to `AVAudioEngine` (`playerNode.volume` +
    /// `streamSourceNode?.volume`) and to `videoPlaybackController.volume`.
    /// Idempotent — same-value writes short-circuit before reaching the
    /// audio backends. This is the gesture-tick choke point that keeps the
    /// main run loop free for SwiftUI rendering during slider drag (mwvi
    /// Phase 0 / Phase 1B+ fix).
    func setVolume(_ vol: Float) {
        guard audioPlayer.volume != vol else { return }
        audioPlayer.volume = vol
    }

    /// Routes balance through `AudioPlayer`. `AudioPlayer.balance.didSet`
    /// applies the value via `AVAudioEngine` (`playerNode.pan` +
    /// `streamSourceNode?.pan`). Idempotent — same-value writes short-circuit.
    func setBalance(_ bal: Float) {
        guard audioPlayer.balance != bal else { return }
        audioPlayer.balance = bal
    }

    /// Drag-end forwarder — writes current `volume` to `UserDefaults`.
    /// Called from `WinampVolumeSlider.onDragEnded` to keep persistence off
    /// the gesture-tick path (Phase 1B fix; see mwvi Phase 0 results).
    func commitVolume() { audioPlayer.commitVolumeToDefaults() }

    /// Drag-end forwarder for balance. See `commitVolume()`.
    func commitBalance() { audioPlayer.commitBalanceToDefaults() }

    // MARK: - Unified Playback Control

    /// Stop both backends and deactivate the stream bridge.
    /// Shared teardown used before switching sources or stopping entirely.
    private func stopAllBackends() {
        audioPlayer.deactivateStreamBridge()
        audioPlayer.stop()
        streamPlayer.stop()
    }

    /// Play a track from the playlist (supports both local files and streams)
    func play(track: Track) async {
        audioPlayer.updatePlaylistPosition(with: track)
        currentTrack = track

        if track.isStream {
            stopAllBackends()

            // Play stream via StreamPlayer (bridge activates via onFormatReady callback)
            await streamPlayer.play(url: track.url, title: track.title, artist: track.artist)
            currentSource = .radioStation(RadioStation(name: track.title, streamURL: track.url))
            currentTitle = track.title
            clearArtwork()
        } else {
            stopAllBackends()

            // Play local file via AudioPlayer
            audioPlayer.playTrack(track: track)
            updateLocalPlaybackState(for: track)
        }
        updateNowPlayingInfo()
    }

    /// Play a radio station from favorites menu
    func play(station: RadioStation) async {
        stopAllBackends()

        // Play stream
        await streamPlayer.play(station: station)
        currentSource = .radioStation(station)
        currentTitle = streamPlayer.streamTitle ?? station.name
        currentTrack = nil  // Not from playlist
        clearArtwork()
        updateNowPlayingInfo()
    }

    func pause() {
        switch currentSource {
        case .localTrack:
            audioPlayer.pause()
        case .radioStation:
            streamPlayer.pause()
        case .none:
            break
        }
        updateNowPlayingInfo()
    }

    func stop() {
        stopAllBackends()
        currentSource = nil
        currentTitle = nil
        currentTrack = nil  // Clear so playlist highlighting resets
        clearNowPlayingInfo()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else if isPaused {
            resume()
        } else if let track = currentTrack {
            // Idle with a selected track (e.g., just restored from playlist.m3u
            // on launch, or after Stop). Play from the beginning.
            Task { await play(track: track) }
        }
    }

    /// Set the playlist selection to the given track without starting playback.
    /// Used by Spec 005 auto-restore and `Load List`'s currentIndex application
    /// to reinstate the previously-current row without auto-resuming. `currentSource`
    /// is intentionally left nil — `togglePlayPause` calls `play(track:)` when
    /// idle-with-selection, which sets it correctly per the track type.
    func selectTrack(_ track: Track) {
        audioPlayer.selectTrackForPlayback(track)
        currentTrack = track
        currentTitle = track.isStream
            ? track.title
            : formattedLocalDisplayTitle(
                trackTitle: track.title,
                trackArtist: track.artist,
                url: track.url
            )
    }

    /// Navigate to next track in playlist
    func next() async {
        // Pass coordinator's currentTrack so PlaylistController can resolve position
        // even when audioPlayer.currentTrack is nil (e.g., during stream playback)
        let action = audioPlayer.nextTrack(from: currentTrack, isManualSkip: true)
        await handlePlaylistAdvance(action: action)
    }

    /// Navigate to previous track in playlist
    func previous() async {
        // Pass coordinator's currentTrack for position context during stream playback
        let action = audioPlayer.previousTrack(from: currentTrack)
        await handlePlaylistAdvance(action: action)
    }

    func resume() {
        switch currentSource {
        case .localTrack:
            audioPlayer.play()
        case .radioStation:
            streamPlayer.resume()
        case .none:
            break
        }
        updateNowPlayingInfo()
    }

    // MARK: - Helpers

    private func formattedLocalDisplayTitle(trackTitle: String, trackArtist: String, url: URL) -> String {
        let trimmedTitle = trackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = trackArtist.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedTitle.isEmpty && !trimmedArtist.isEmpty {
            return "\(trimmedArtist) - \(trimmedTitle)"
        }

        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        if !trimmedArtist.isEmpty {
            return trimmedArtist
        }

        return url.deletingPathExtension().lastPathComponent
    }

    private func updateLocalPlaybackState(for track: Track) {
        currentTrack = track
        currentSource = .localTrack(track.url)
        currentTitle = formattedLocalDisplayTitle(
            trackTitle: track.title,
            trackArtist: track.artist,
            url: track.url
        )
        resolveArtwork(for: track.url)
    }

    /// Resolve cover art for a local file off the main actor and refresh Now Playing
    /// when it arrives. Clears any prior artwork immediately so stale art doesn't
    /// linger across a track change.
    private func resolveArtwork(for url: URL) {
        artworkRequestID &+= 1
        let requestID = artworkRequestID
        currentArtwork = nil

        Task { [weak self] in
            let artwork = await CoverArtLoader.loadCoverArt(for: url)
            guard let self, requestID == self.artworkRequestID else { return }
            self.currentArtwork = artwork
            self.updateNowPlayingInfo()
        }
    }

    /// Drop the current artwork and cancel any in-flight resolution. Used when the
    /// source has no artwork (streams) or playback stops.
    private func clearArtwork() {
        artworkRequestID &+= 1
        currentArtwork = nil
    }

    private func handlePlaylistAdvance(action: AudioPlayer.PlaylistAdvanceAction) async {
        switch action {
        case .none:
            return
        case .restartCurrent:
            guard let track = currentTrack else { return }
            if track.isStream {
                await play(track: track)
            } else {
                updateLocalPlaybackState(for: track)
            }
        case .playLocally(let track):
            // Only stop stream side — AudioPlayer already started this track
            audioPlayer.deactivateStreamBridge()
            streamPlayer.stop()
            updateLocalPlaybackState(for: track)
        case .requestCoordinatorPlayback(let track):
            await play(track: track)
        }
        updateNowPlayingInfo()
    }

    /// Update coordinator state when metadata loads (don't replay)
    func updateTrackMetadata(_ track: Track) {
        // Check URL match (not ID - metadata loading creates new Track with different ID)
        guard let current = currentTrack, current.url == track.url else { return }

        // Update with real metadata
        currentTrack = track
        currentTitle = formattedLocalDisplayTitle(
            trackTitle: track.title,
            trackArtist: track.artist,
            url: track.url
        )

        // Note: Don't call play(track:) - that would replay the file
        // Just update metadata for display
        updateNowPlayingInfo()
    }

    private func handleExternalPlaylistAdvance(track: Track) async {
        if track.isStream {
            await play(track: track)
        } else {
            updateLocalPlaybackState(for: track)
        }
        updateNowPlayingInfo()
    }

    // MARK: - Unified State for UI

    /// Display title for main window (includes buffering status)
    var displayTitle: String {
        switch currentSource {
        case .radioStation:
            // Buffering takes priority
            if streamPlayer.isBuffering {
                return "Connecting..."
            }
            // Error state — show user-friendly message
            if let streamError = streamPlayer.error {
                return streamError
            }
            // Station name (from RadioStation or track title)
            let stationName = streamPlayer.currentStation?.name ?? currentTrack?.title ?? currentTitle ?? "Internet Radio"

            // Combine station name + ICY track title (scrollable in Winamp title bar)
            if let icy = streamPlayer.streamTitle {
                return "\(stationName) - \(icy)"
            }
            return stationName

        case .localTrack(let url):
            let posPrefix = trackPositionString.map { "\($0). " } ?? ""

            if let title = currentTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                return "\(posPrefix)\(title)"
            }

            let fallbackTitle = formattedLocalDisplayTitle(
                trackTitle: currentTrack?.title ?? "",
                trackArtist: currentTrack?.artist ?? "",
                url: url
            )

            return "\(posPrefix)\(fallbackTitle.isEmpty ? "Unknown" : fallbackTitle)"

        case .none:
            return "MacAmp"
        }
    }

    /// Display artist for main window
    var displayArtist: String {
        switch currentSource {
        case .radioStation:
            // ICY metadata (overrides Track artist)
            return streamPlayer.streamArtist ?? currentTrack?.artist ?? ""
        case .localTrack:
            return currentTrack?.artist ?? ""
        case .none:
            return ""
        }
    }

    /// Bare song title for the system Now Playing center, or `nil` when none is
    /// available so the caller can omit `MPMediaItemPropertyTitle` entirely.
    ///
    /// `displayTitle` is the composed main-window scroller string
    /// (`"<pos>. <artist> - <title>"`); feeding that to `MPMediaItemPropertyTitle`
    /// mistypes the field and duplicates the artist that `MPMediaItemPropertyArtist`
    /// already carries. This is the plain title that field expects.
    private var nowPlayingTitle: String? {
        switch currentSource {
        case .radioStation:
            return streamPlayer.streamTitle ?? streamPlayer.currentStation?.name
        case .localTrack:
            return currentTrack?.title
        case .none:
            return nil
        }
    }

    // MARK: - Legacy State Queries (for compatibility)

    var streamTitle: String? {
        switch currentSource {
        case .localTrack(let url):
            return url.deletingPathExtension().lastPathComponent
        case .radioStation:
            return streamPlayer.streamTitle
        case .none:
            return nil
        }
    }

    var streamArtist: String? {
        streamPlayer.streamArtist
    }

    var isBuffering: Bool {
        streamPlayer.isBuffering
    }

    var error: String? {
        streamPlayer.error
    }

    // MARK: - Now Playing & Remote Commands

    /// Update the system Now Playing info center with current track/stream metadata.
    /// Called at every playback state transition. Apple auto-extrapolates elapsed time
    /// from the last provided value + playback rate — no periodic timer needed.
    func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()

        guard currentSource != nil else {
            clearNowPlayingInfo()
            return
        }

        var info = [String: Any]()
        if let title = nowPlayingTitle, !title.isEmpty {
            info[MPMediaItemPropertyTitle] = title
        }
        if !displayArtist.isEmpty {
            info[MPMediaItemPropertyArtist] = displayArtist
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = displayTime
        info[MPMediaItemPropertyPlaybackDuration] = displayDuration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if let currentArtwork {
            info[MPMediaItemPropertyArtwork] = currentArtwork
        }
        center.nowPlayingInfo = info

        // REQUIRED on macOS — explicit playback state.
        // Use coordinator state (isPlaying/isPaused), not audioPlayer.playbackState,
        // because stream pause/buffering is owned by StreamPlayer/PlaybackCoordinator.
        if isPlaying {
            center.playbackState = .playing
        } else if isPaused {
            center.playbackState = .paused
        } else if streamPlayer.isBuffering {
            // Stream buffering: not playing but not stopped — keep as paused
            // to avoid losing the Now Playing item during reconnect
            center.playbackState = .paused
        } else {
            center.playbackState = .stopped
        }

        // Disable seek for streams (no duration), enable for local files
        let seekEnabled = currentSource.map { if case .localTrack = $0 { return true } else { return false } } ?? false
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.changePlaybackPositionCommand.isEnabled = seekEnabled

        // Disable next/previous when no playlist position context.
        // currentTrack is nil when playing a direct station (not from playlist),
        // even if the playlist has tracks loaded. Without a position, next/previous
        // would jump to track 0 unexpectedly.
        let hasPlaylistContext = currentTrack != nil && audioPlayer.playlistCount > 0
        commandCenter.nextTrackCommand.isEnabled = hasPlaylistContext
        commandCenter.previousTrackCommand.isEnabled = hasPlaylistContext
    }

    /// Clear Now Playing info and set playback state to stopped.
    /// Disables all context-dependent remote commands (seek, next, previous).
    private func clearNowPlayingInfo() {
        clearArtwork()
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.changePlaybackPositionCommand.isEnabled = false
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
    }

}
