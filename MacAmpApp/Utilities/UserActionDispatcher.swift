import AppKit
import Observation

/// Single dispatch point for every `UserAction`. All click handlers, hotkey
/// monitors, menu items, and remote-command targets call `perform(_:)` here
/// — they never touch the audio backends or settings directly. That makes
/// the underlying behavior of each action unique by construction (button
/// and hotkey can't drift apart), and gives the action wiring one place to
/// audit when new actions are added.
@MainActor
@Observable
final class UserActionDispatcher {
    private let audioPlayer: AudioPlayer
    private let playbackCoordinator: PlaybackCoordinator
    private let dockingController: DockingController
    private let settings: AppSettings
    private let presentOpenPanel: () -> Void

    init(
        audioPlayer: AudioPlayer,
        playbackCoordinator: PlaybackCoordinator,
        dockingController: DockingController,
        settings: AppSettings,
        presentOpenPanel: @escaping () -> Void
    ) {
        self.audioPlayer = audioPlayer
        self.playbackCoordinator = playbackCoordinator
        self.dockingController = dockingController
        self.settings = settings
        self.presentOpenPanel = presentOpenPanel
    }

    func perform(_ action: UserAction) {
        switch action {
        case .togglePlayPause:
            playbackCoordinator.togglePlayPause()
        case .startPlayback:
            startPlayback()
        case .play:
            playbackCoordinator.resume()
        case .pause:
            playbackCoordinator.pause()
        case .stop:
            playbackCoordinator.stop()
        case .previousTrack:
            Task { await playbackCoordinator.previous() }
        case .nextTrack:
            Task { await playbackCoordinator.next() }
        case .seekBy(let seconds):
            seekBy(seconds)
        case .seekTo(let seconds):
            audioPlayer.seek(to: seconds)
        case .adjustVolume(let percent):
            adjustVolume(by: percent)
        case .toggleShuffle:
            audioPlayer.shuffleEnabled.toggle()
        case .cycleRepeatMode:
            audioPlayer.repeatMode = audioPlayer.repeatMode.next()
        case .openFiles:
            presentOpenPanel()
        case .addLocation:
            PlaylistWindowActions.shared.presentAddURLPrompt(audioPlayer: audioPlayer)
        case .loadPlaylist:
            PlaylistWindowActions.shared.presentLoadPlaylistPanel(audioPlayer: audioPlayer)
        case .toggleMainWindow:
            dockingController.toggleMain()
        case .togglePlaylistWindow:
            _ = WindowCoordinator.shared?.togglePlaylistWindowVisibility()
        case .toggleEqualizerWindow:
            _ = WindowCoordinator.shared?.toggleEQWindowVisibility()
        case .toggleVideoWindow:
            settings.showVideoWindow.toggle()
        case .toggleMilkdropWindow:
            settings.showMilkdropWindow.toggle()
        case .shadeMainWindow:
            settings.isMainWindowShaded.toggle()
        case .shadePlaylistWindow:
            settings.isPlaylistWindowShaded.toggle()
        case .shadeEqualizerWindow:
            settings.isEqualizerWindowShaded.toggle()
        case .minimizeApp:
            WindowCoordinator.shared?.hideApp()
        case .quitApp:
            NSApplication.shared.terminate(nil)
        case .toggleAlwaysOnTop:
            settings.isAlwaysOnTop.toggle()
        case .toggleDoubleSize:
            settings.isDoubleSizeMode.toggle()
        case .toggleTimeDisplayMode:
            settings.toggleTimeDisplayMode()
        case .showTrackInfo:
            showTrackInfo()
        case .showOptionsMenu:
            settings.showOptionsMenuTrigger = true
        case .openPreferences:
            settings.showPreferencesTrigger = true
        case .toggleEqualizerEnabled:
            audioPlayer.toggleEq(isOn: !audioPlayer.isEqOn)
        case .toggleEqualizerAuto:
            audioPlayer.setAutoEQEnabled(!audioPlayer.eqAutoEnabled)
        }
    }

    // MARK: Helpers

    /// Webamp's `play()` thunk: resume if paused, start the current track if
    /// idle, no-op if already playing. Used by the `X` hotkey.
    private func startPlayback() {
        if playbackCoordinator.isPaused {
            playbackCoordinator.togglePlayPause()
        } else if !playbackCoordinator.isPlaying {
            audioPlayer.play()
        }
    }

    /// Open File Info on the resolved target. With no target and no stream
    /// playing the panel has nothing to describe, so the action does nothing
    /// rather than putting up a window that only says so.
    private func showTrackInfo() {
        let target = trackInfoTarget()
        guard target != nil || isPlayingStream else { return }
        settings.trackInfoTrack = target
        WindowCoordinator.shared?.showTrackInfo()
    }

    private var isPlayingStream: Bool {
        if case .radioStation = playbackCoordinator.currentSource { return true }
        return false
    }

    /// File Info target, matching Winamp: the playlist editor shows info for the
    /// selected item, the main window for the playing track. Prefer the
    /// (first) selected playlist track; fall back to the playing track.
    private func trackInfoTarget() -> Track? {
        let playlist = audioPlayer.playlist
        if let first = PlaylistWindowActions.shared.selectedIndices.sorted().first,
           playlist.indices.contains(first) {
            return playlist[first]
        }
        return audioPlayer.currentTrack
    }

    /// Local-file relative seek. No-op for streams (no seekable timeline).
    private func seekBy(_ seconds: Double) {
        guard case .localTrack = playbackCoordinator.currentSource else { return }
        // `currentTime` is quantized to whole seconds for display; use the live
        // position so a relative seek lands accurately.
        let newTime = max(0, audioPlayer.livePlaybackTime + seconds)
        audioPlayer.seek(to: newTime)
    }

    /// ±1% volume adjustment with same-value short-circuit. Mirrors the
    /// gesture-tick choke-point pattern of slider drags, but also commits
    /// to UserDefaults since arrow-key presses are discrete actions with
    /// no "drag end" moment.
    private func adjustVolume(by deltaPercent: Int) {
        let currentPct = Int((audioPlayer.volume * 100).rounded())
        let newPct = max(0, min(100, currentPct + deltaPercent))
        guard newPct != currentPct else { return }
        playbackCoordinator.setVolume(Float(newPct) / 100)
        playbackCoordinator.commitVolume()
    }
}
