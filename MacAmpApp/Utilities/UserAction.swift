import Foundation

/// Every discrete user-triggerable action in the app — anything the user can
/// invoke by clicking a button, picking a menu item, pressing a hotkey, or
/// hitting a media key. Each action has exactly one implementation in
/// `UserActionDispatcher.perform(_:)`, so a button and its matching hotkey
/// can't drift apart.
///
/// Continuous gestures (slider drags, scroll-wheel volume, EQ-band drags)
/// are NOT actions — they remain direct calls to the audio backends.
enum UserAction: Hashable, Sendable {
    // MARK: Playback

    /// Play/pause toggle. Webamp's `c` key and every transport pause button.
    case togglePlayPause

    /// "Play" semantics from Winamp's `x` key: keep playing if already
    /// playing, resume if paused, otherwise restart the current track.
    case startPlayback

    /// Resume-only — for media remote `playCommand`. No-op when not paused.
    case play

    /// Pause-only — for media remote `pauseCommand`. No-op when not playing.
    case pause

    case stop
    case previousTrack
    case nextTrack

    /// Relative seek used by ←/→ arrows.
    case seekBy(seconds: Double)

    /// Absolute seek (for media remote `changePlaybackPositionCommand`).
    case seekTo(seconds: Double)

    // MARK: Volume

    /// Discrete volume adjustment used by ↑/↓ arrows. Slider drags bypass
    /// this and call `PlaybackCoordinator.setVolume` directly.
    case adjustVolume(percent: Int)

    // MARK: Playback modes

    case toggleShuffle
    case cycleRepeatMode

    // MARK: File I/O

    case openFiles

    /// Prompt for an internet-radio stream URL and add it to the playlist.
    case addLocation

    /// Prompt for an M3U playlist file and load it.
    case loadPlaylist

    // MARK: Window visibility

    case toggleMainWindow
    case togglePlaylistWindow
    case toggleEqualizerWindow
    case toggleVideoWindow
    case toggleMilkdropWindow

    // MARK: Window shade

    case shadeMainWindow
    case shadePlaylistWindow
    case shadeEqualizerWindow

    // MARK: App lifecycle

    case minimizeApp
    case quitApp

    // MARK: Display modes

    case toggleAlwaysOnTop
    case toggleDoubleSize
    case toggleTimeDisplayMode

    // MARK: Dialogs and overlays

    case showTrackInfo
    case showOptionsMenu
    case openPreferences

    // MARK: Equalizer

    case toggleEqualizerEnabled
    case toggleEqualizerAuto
}
