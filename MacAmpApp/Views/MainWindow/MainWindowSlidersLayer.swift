import SwiftUI

/// Volume, balance, and position sliders.
/// Only re-evaluates when volume/balance/progress or scrubbing state changes.
struct MainWindowSlidersLayer: View {
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    let interactionState: WinampMainWindowInteractionState

    private typealias Layout = WinampMainWindowLayout

    var body: some View {
        MainWindowPositionSlider(interactionState: interactionState)
        buildVolumeSlider()
        buildBalanceSlider()
    }

    @ViewBuilder
    private func buildVolumeSlider() -> some View {
        let volumeBinding = Binding<Float>(
            get: { audioPlayer.volume },
            set: { playbackCoordinator.setVolume($0) }
        )
        WinampVolumeSlider(
            volume: volumeBinding,
            onDragEnded: { playbackCoordinator.commitVolume() }
        )
        .at(Layout.volumeSlider)
    }

    @ViewBuilder
    private func buildBalanceSlider() -> some View {
        let balanceBinding = Binding<Float>(
            get: { audioPlayer.balance },
            set: { playbackCoordinator.setBalance($0) }
        )
        WinampBalanceSlider(
            balance: balanceBinding,
            onDragEnded: { playbackCoordinator.commitBalance() }
        )
        .at(Layout.balanceSlider)
    }
}

/// Position (seek) slider, split out so the ~10 Hz progress update re-renders
/// only the thumb instead of the volume and balance sliders alongside it.
///
/// This outer view does not read `playbackProgress`, so a progress tick
/// re-evaluates only `PositionSliderThumb` — the static background and the
/// gesture reader are left untouched.
struct MainWindowPositionSlider: View {
    @Environment(AudioPlayer.self) private var audioPlayer
    let interactionState: WinampMainWindowInteractionState

    private typealias Layout = WinampMainWindowLayout

    var body: some View {
        if audioPlayer.currentTrack != nil {
            ZStack(alignment: .topLeading) {
                SimpleSpriteImage("MAIN_POSITION_SLIDER_BACKGROUND", width: 248, height: 10)
                    .at(Layout.positionSlider)

                PositionSliderThumb(interactionState: interactionState)

                GeometryReader { geo in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in interactionState.handlePositionDrag(value, in: geo, audioPlayer: audioPlayer) }
                                .onEnded { value in interactionState.handlePositionDragEnd(value, in: geo, audioPlayer: audioPlayer) }
                        )
                }
                .frame(width: 248, height: 10)
                .at(Layout.positionSlider)
            }
        }
    }
}

/// The moving seek thumb. Isolated so the 10 Hz progress write re-renders only
/// this sprite, not the slider background or its drag-gesture reader.
private struct PositionSliderThumb: View {
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(AppSettings.self) private var settings
    @Environment(\.displayScale) private var displayScale
    let interactionState: WinampMainWindowInteractionState

    private typealias Layout = WinampMainWindowLayout

    /// Screen pixels per layout point, including the double-size scale effect
    /// the whole window is drawn under.
    private var pixelsPerPoint: CGFloat {
        displayScale * (settings.isDoubleSizeMode ? 2 : 1)
    }

    /// Truncates an offset to a whole screen pixel, so the thumb advances one
    /// pixel at a time and its sprite lands on the pixel grid.
    private func snappedToPixel(_ offset: CGFloat) -> CGFloat {
        guard pixelsPerPoint > 0 else { return offset }
        return (offset * pixelsPerPoint).rounded(.down) / pixelsPerPoint
    }

    var body: some View {
        let currentProgress = interactionState.isScrubbing ? interactionState.scrubbingProgress : audioPlayer.playbackProgress
        SimpleSpriteImage("MAIN_POSITION_SLIDER_THUMB", width: 29, height: 10)
            .at(CGPoint(x: Layout.positionSlider.x + snappedToPixel((248 - 29) * currentProgress),
                       y: Layout.positionSlider.y))
            .allowsHitTesting(false)
    }
}
