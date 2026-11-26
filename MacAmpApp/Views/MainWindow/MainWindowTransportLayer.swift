import SwiftUI

/// Transport playback buttons: previous, play, pause, stop, next, eject.
/// Separate View struct creates a recomposition boundary — only re-evaluates
/// when PlaybackCoordinator state actually used by these buttons changes.
struct MainWindowTransportLayer: View {
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(UserActionDispatcher.self) private var dispatcher

    private typealias Layout = WinampMainWindowLayout

    var body: some View {
        // Playback buttons
        Button(action: { dispatcher.perform(.previousTrack) }, label: {
            SimpleSpriteImage("MAIN_PREVIOUS_BUTTON", width: 23, height: 18)
        })
        .buttonStyle(.plain)
        .focusable(false)
        .help("Previous track (Z)")
        .at(Layout.prevButton)

        Button(action: { dispatcher.perform(.togglePlayPause) }, label: {
            SimpleSpriteImage("MAIN_PLAY_BUTTON", width: 23, height: 18)
        })
        .buttonStyle(.plain)
        .focusable(false)
        .help(playbackCoordinator.isPlaying ? "Pause (C)" : "Play (C)")
        .at(Layout.playButton)

        Button(action: { dispatcher.perform(.togglePlayPause) }, label: {
            SimpleSpriteImage("MAIN_PAUSE_BUTTON", width: 23, height: 18)
        })
        .buttonStyle(.plain)
        .focusable(false)
        .help(playbackCoordinator.isPlaying ? "Pause (C)" : "Play (C)")
        .at(Layout.pauseButton)

        // Nav buttons
        Button(action: { dispatcher.perform(.stop) }, label: {
            SimpleSpriteImage("MAIN_STOP_BUTTON", width: 23, height: 18)
        })
        .buttonStyle(.plain)
        .focusable(false)
        .help("Stop (V)")
        .at(Layout.stopButton)

        Button(action: { dispatcher.perform(.nextTrack) }, label: {
            SimpleSpriteImage("MAIN_NEXT_BUTTON", width: 23, height: 18)
        })
        .buttonStyle(.plain)
        .focusable(false)
        .help("Next track (B)")
        .at(Layout.nextButton)

        Button(action: { dispatcher.perform(.openFiles) }, label: {
            SimpleSpriteImage("MAIN_EJECT_BUTTON", width: 22, height: 16)
        })
        .buttonStyle(.plain)
        .focusable(false)
        .help("Open files (L)")
        .at(Layout.ejectButton)
    }
}
