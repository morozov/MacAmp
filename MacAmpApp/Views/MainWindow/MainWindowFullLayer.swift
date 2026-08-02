import SwiftUI

/// Full-mode main window composition — assembles all child layers plus
/// small builders (titlebar, shuffle/repeat, clutter bar, time, visualizer).
struct MainWindowFullLayer: View {
    @Environment(SkinManager.self) private var skinManager
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(AppSettings.self) private var settings
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(WindowFocusState.self) private var windowFocusState
    @Environment(UserActionDispatcher.self) private var dispatcher

    let interactionState: WinampMainWindowInteractionState

    private typealias Layout = WinampMainWindowLayout

    var body: some View {
        Group {
            // All button sprites drawn in one Canvas layer; the buttons below
            // are transparent hit targets over it.
            MainWindowButtonSprites()

            // Titlebar buttons
            buildTitlebarButtons()

            // Indicators (play/pause, mono/stereo, bitrate, sample rate)
            MainWindowIndicatorsLayer(pauseBlinkVisible: interactionState.pauseBlinkVisible)

            // Time display
            MainWindowTimeLayer(interactionState: interactionState)

            // Track info (scrolling text)
            MainWindowTrackInfoLayer(interactionState: interactionState)

            // Spectrum analyzer
            buildSpectrumAnalyzer()

            // Transport buttons
            MainWindowTransportLayer()

            // Shuffle/Repeat buttons
            buildShuffleRepeatButtons()

            // Sliders (position, volume, balance)
            MainWindowSlidersLayer(interactionState: interactionState)

            // EQ/Playlist window toggles
            buildWindowToggleButtons()

            // Clutter bar buttons (O, A, I, D, V)
            buildClutterBarOAI()
            buildClutterBarDV()
        }
    }

    // MARK: - Titlebar Buttons

    @ViewBuilder
    private func buildTitlebarButtons() -> some View {
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

    // MARK: - Time Display

    // MARK: - Spectrum Analyzer

    @ViewBuilder
    private func buildSpectrumAnalyzer() -> some View {
        VisualizerView()
            .frame(width: VisualizerLayout.width, height: VisualizerLayout.height)
            .at(Layout.spectrumAnalyzer)
    }

    // MARK: - Shuffle/Repeat

    @ViewBuilder
    private func buildShuffleRepeatButtons() -> some View {
        Group {
            Button(action: { dispatcher.perform(.toggleShuffle) }, label: {
                let spriteKey = audioPlayer.shuffleEnabled ? "MAIN_SHUFFLE_BUTTON_SELECTED" : "MAIN_SHUFFLE_BUTTON"
                SimpleSpriteImage(spriteKey, width: 47, height: 15)
            })
            .buttonStyle(.plain)
            .focusable(false)
            .at(Layout.shuffleButton)

            Button(action: { dispatcher.perform(.cycleRepeatMode) }, label: {
                let spriteKey = audioPlayer.repeatMode.isActive ? "MAIN_REPEAT_BUTTON_SELECTED" : "MAIN_REPEAT_BUTTON"
                SimpleSpriteImage(spriteKey, width: 28, height: 15)
            })
            .buttonStyle(.plain)
            .focusable(false)
            .help(audioPlayer.repeatMode.label)
            .at(Layout.repeatButton)
        }
    }

    // MARK: - Window Toggle Buttons

    @ViewBuilder
    private func buildWindowToggleButtons() -> some View {
        // Read through the observable box: `WindowCoordinator.shared` is a
        // plain static the Observation runtime can't track, so a view body
        // that resolved it at first eval would lock in `nil`.
        let coordinator = WindowCoordinatorBox.shared.value
        let eqVisible = coordinator?.isEQWindowVisible ?? false
        let playlistVisible = coordinator?.isPlaylistWindowVisible ?? false

        Group {
            Button(action: { dispatcher.perform(.toggleEqualizerWindow) }, label: {
                SimpleSpriteImage(eqVisible ? "MAIN_EQ_BUTTON_SELECTED" : "MAIN_EQ_BUTTON", width: 23, height: 12)
            })
            .buttonStyle(.plain)
            .focusable(false)
            .at(Layout.eqButton)

            Button(action: { dispatcher.perform(.togglePlaylistWindow) }, label: {
                SimpleSpriteImage(playlistVisible ? "MAIN_PLAYLIST_BUTTON_SELECTED" : "MAIN_PLAYLIST_BUTTON", width: 23, height: 12)
            })
            .buttonStyle(.plain)
            .focusable(false)
            .at(Layout.playlistButton)
        }
    }

    // MARK: - Clutter Bar

    @ViewBuilder
    private func buildClutterBarOAI() -> some View {
        Button(action: { dispatcher.perform(.showOptionsMenu) }, label: {
            SimpleSpriteImage("MAIN_CLUTTER_BAR_BUTTON_O", width: 8, height: 8)
        })
        .buttonStyle(.plain)
        .focusable(false)
        .help("Options menu (\(WinampKeyBindings.openOptionsMenu.displayLabel), \(WinampKeyBindings.timeMode.displayLabel) for time)")
        .at(Layout.clutterButtonO)

        let aSprite = settings.isAlwaysOnTop ? "MAIN_CLUTTER_BAR_BUTTON_A_SELECTED" : "MAIN_CLUTTER_BAR_BUTTON_A"
        Button(action: { dispatcher.perform(.toggleAlwaysOnTop) }, label: {
            SimpleSpriteImage(aSprite, width: 8, height: 7)
        })
        .buttonStyle(.plain)
        .focusable(false)
        .help("Toggle always on top (\(WinampKeyBindings.alwaysOnTop.displayLabel))")
        .at(Layout.clutterButtonA)

        let iSprite = settings.showTrackInfoDialog ? "MAIN_CLUTTER_BAR_BUTTON_I_SELECTED" : "MAIN_CLUTTER_BAR_BUTTON_I"
        Button(action: { dispatcher.perform(.showTrackInfo) }, label: {
            SimpleSpriteImage(iSprite, width: 8, height: 7)
        })
        .buttonStyle(.plain)
        .focusable(false)
        .help("Track information (\(WinampKeyBindings.trackInfo.displayLabel))")
        .at(Layout.clutterButtonI)
    }

    @ViewBuilder
    private func buildClutterBarDV() -> some View {
        let dSprite = settings.isDoubleSizeMode ? "MAIN_CLUTTER_BAR_BUTTON_D_SELECTED" : "MAIN_CLUTTER_BAR_BUTTON_D"
        Button(action: { dispatcher.perform(.toggleDoubleSize) }, label: {
            SimpleSpriteImage(dSprite, width: 8, height: 8)
        })
        .buttonStyle(.plain)
        .focusable(false)
        .help("Toggle window size")
        .at(Layout.clutterButtonD)

        let vSprite = settings.showVideoWindow ? "MAIN_CLUTTER_BAR_BUTTON_V_SELECTED" : "MAIN_CLUTTER_BAR_BUTTON_V"
        Button(action: { dispatcher.perform(.toggleVideoWindow) }, label: {
            SimpleSpriteImage(vSprite, width: 8, height: 7)
        })
        .buttonStyle(.plain)
        .focusable(false)
        .help("Video Window (\(WinampKeyBindings.videoWindow.displayLabel))")
        .at(Layout.clutterButtonV)
    }
}
