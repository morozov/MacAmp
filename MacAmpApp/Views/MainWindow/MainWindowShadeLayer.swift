import SwiftUI

/// Shade (collapsed) mode — minimal transport, time display, and titlebar buttons.
struct MainWindowShadeLayer: View {
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(AppSettings.self) private var settings
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(WindowFocusState.self) private var windowFocusState
    @Environment(UserActionDispatcher.self) private var dispatcher

    let interactionState: WinampMainWindowInteractionState

    private typealias Layout = WinampMainWindowLayout

    var body: some View {
        ZStack(alignment: .topLeading) {
            SimpleSpriteImage("MAIN_SHADE_BACKGROUND", width: 275, height: 14)
                .at(CGPoint(x: 0, y: 0))

            // Drag-capture below the time display and titlebar buttons, so
            // those keep their click handlers while the rest of the strip
            // moves the window. Without it, MAIN_SHADE_BACKGROUND swallows
            // every click and the outer `WinampTitlebarDragHandle` (which
            // sits beneath this shade layer in `WinampMainWindow`) never
            // sees the drag.
            let buttonsWidth: CGFloat = 275 - Layout.minimizeButton.x
            TitlebarDragCaptureView(windowKind: .main)
                .frame(width: max(0, 275 - buttonsWidth), height: 14)
                .at(CGPoint(x: 0, y: 0))

            buildShadeTimeDisplay()
            buildShadeTitlebarButtons()
        }
    }

    // MARK: - Shade Time Display

    @ViewBuilder
    private func buildShadeTimeDisplay() -> some View {
        ZStack(alignment: .leading) {
            if settings.timeDisplayMode == .remaining && playbackCoordinator.displayDuration > 0 {
                ZStack(alignment: .topLeading) {
                    SimpleSpriteImage(.minusSign, width: 5, height: 1)
                        .offset(x: 0, y: 6)
                }
                .frame(width: 9, height: 13, alignment: .topLeading)
                .offset(x: 1, y: 0)
            }

            let duration = playbackCoordinator.displayDuration
            let timeToShow = settings.timeDisplayMode == .remaining && duration > 0
                ? max(0.0, duration - playbackCoordinator.displayTime)
                : playbackCoordinator.displayTime
            let digits = interactionState.timeDigits(from: timeToShow)
            let shouldShowDigits = !playbackCoordinator.isPaused || interactionState.pauseBlinkVisible

            if shouldShowDigits {
                SimpleSpriteImage(.digit(digits[0]), width: 9, height: 13).offset(x: 6, y: 0)
                SimpleSpriteImage(.digit(digits[1]), width: 9, height: 13).offset(x: 17, y: 0)
            }
            if shouldShowDigits {
                SimpleSpriteImage(.digit(digits[2]), width: 9, height: 13).offset(x: 35, y: 0)
                SimpleSpriteImage(.digit(digits[3]), width: 9, height: 13).offset(x: 46, y: 0)
            }
        }
        .frame(width: 56, height: 13, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            dispatcher.perform(.toggleTimeDisplayMode)
        }
        .at(Layout.timeDisplay)
        .scaleEffect(0.7)
        .at(CGPoint(x: 150, y: 7))
    }

    // MARK: - Shade Titlebar Buttons

    @ViewBuilder
    private func buildShadeTitlebarButtons() -> some View {
        Group {
            Button(action: { dispatcher.perform(.minimizeApp) }, label: {
                SimpleSpriteImage("MAIN_MINIMIZE_BUTTON", width: 9, height: 9)
            })
            .buttonStyle(.plain)
            .focusable(false)
            .at(Layout.minimizeButton)

            Button(action: { dispatcher.perform(.shadeMainWindow) }, label: {
                SimpleSpriteImage("MAIN_SHADE_BUTTON", width: 9, height: 9)
            })
            .buttonStyle(.plain)
            .focusable(false)
            .at(Layout.shadeButton)

            Button(action: { dispatcher.perform(.quitApp) }, label: {
                SimpleSpriteImage("MAIN_CLOSE_BUTTON", width: 9, height: 9)
            })
            .buttonStyle(.plain)
            .focusable(false)
            .at(Layout.closeButton)
        }
    }
}
