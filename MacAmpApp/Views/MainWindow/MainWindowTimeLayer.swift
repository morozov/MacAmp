import SwiftUI

/// MM:SS time readout for the full-mode main window.
///
/// Split out of `MainWindowFullLayer` so the once-per-tick playback-time
/// update re-renders only these digits. When the readout was an inline builder
/// in `MainWindowFullLayer.body`, reading `displayTime` made the whole body
/// depend on it, so every tick rebuilt every sibling sprite layer.
struct MainWindowTimeLayer: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(UserActionDispatcher.self) private var dispatcher

    let interactionState: WinampMainWindowInteractionState

    private typealias Layout = WinampMainWindowLayout

    var body: some View {
        ZStack(alignment: .leading) {
            // Minus sign for remaining time (hidden for streams — no known duration)
            if settings.timeDisplayMode == .remaining && playbackCoordinator.displayDuration > 0 {
                ZStack(alignment: .topLeading) {
                    SimpleSpriteImage(.minusSign, width: 5, height: 1)
                        .offset(x: 0, y: 6)
                }
                .frame(width: 9, height: 13, alignment: .topLeading)
                .offset(x: 1, y: 0)
            }

            timeDigits
        }
        .frame(width: 56, height: 13, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            dispatcher.perform(.toggleTimeDisplayMode)
        }
        .at(Layout.timeDisplay)
    }

    @ViewBuilder
    private var timeDigits: some View {
        let duration = playbackCoordinator.displayDuration
        let timeToShow = settings.timeDisplayMode == .remaining && duration > 0
            ? max(0.0, duration - playbackCoordinator.displayTime)
            : playbackCoordinator.displayTime
        let digits = interactionState.timeDigits(from: timeToShow)
        let shouldShowDigits = !playbackCoordinator.isPaused || interactionState.pauseBlinkVisible

        if shouldShowDigits {
            if digits[0] >= 0 {
                SimpleSpriteImage(.digit(digits[0]), width: 9, height: 13).offset(x: -3, y: 0)
            }
            SimpleSpriteImage(.digit(digits[1]), width: 9, height: 13).offset(x: 8, y: 0)
            SimpleSpriteImage(.digit(digits[2]), width: 9, height: 13).offset(x: 19, y: 0)
        }
        if shouldShowDigits {
            SimpleSpriteImage(.digit(digits[3]), width: 9, height: 13).offset(x: 39, y: 0)
            SimpleSpriteImage(.digit(digits[4]), width: 9, height: 13).offset(x: 50, y: 0)
        }
    }
}
