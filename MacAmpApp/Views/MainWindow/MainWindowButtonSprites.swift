import SwiftUI

/// Draws every main-window button sprite (titlebar, transport, shuffle/repeat,
/// EQ/PL toggles, clutter bar) into a single flattened bitmap. The buttons
/// themselves stay as transparent hit targets in their layers; only their
/// pixels move here, so ~16 per-button `CALayer`s collapse to one. The sprites
/// are visually static during playback (`.buttonStyle(.plain)` shows no pressed
/// state), so this layer is only re-committed when a toggle/skin/focus changes.
struct MainWindowButtonSprites: View {
    @Environment(SkinManager.self) private var skinManager
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(AppSettings.self) private var settings

    private typealias Layout = WinampMainWindowLayout

    /// (sprite key, top-left, size) for every button, in draw order.
    static func sprites(
        shuffle: Bool, repeatActive: Bool,
        eqVisible: Bool, playlistVisible: Bool,
        alwaysOnTop: Bool, trackInfo: Bool, doubleSize: Bool, video: Bool
    ) -> [(String, CGPoint, CGSize)] {
        [
            ("MAIN_MINIMIZE_BUTTON", Layout.minimizeButton, CGSize(width: 9, height: 9)),
            ("MAIN_SHADE_BUTTON", Layout.shadeButton, CGSize(width: 9, height: 9)),
            ("MAIN_CLOSE_BUTTON", Layout.closeButton, CGSize(width: 9, height: 9)),
            ("MAIN_PREVIOUS_BUTTON", Layout.prevButton, CGSize(width: 23, height: 18)),
            ("MAIN_PLAY_BUTTON", Layout.playButton, CGSize(width: 23, height: 18)),
            ("MAIN_PAUSE_BUTTON", Layout.pauseButton, CGSize(width: 23, height: 18)),
            ("MAIN_STOP_BUTTON", Layout.stopButton, CGSize(width: 23, height: 18)),
            ("MAIN_NEXT_BUTTON", Layout.nextButton, CGSize(width: 23, height: 18)),
            ("MAIN_EJECT_BUTTON", Layout.ejectButton, CGSize(width: 22, height: 16)),
            (shuffle ? "MAIN_SHUFFLE_BUTTON_SELECTED" : "MAIN_SHUFFLE_BUTTON", Layout.shuffleButton, CGSize(width: 47, height: 15)),
            (repeatActive ? "MAIN_REPEAT_BUTTON_SELECTED" : "MAIN_REPEAT_BUTTON", Layout.repeatButton, CGSize(width: 28, height: 15)),
            (eqVisible ? "MAIN_EQ_BUTTON_SELECTED" : "MAIN_EQ_BUTTON", Layout.eqButton, CGSize(width: 23, height: 12)),
            (playlistVisible ? "MAIN_PLAYLIST_BUTTON_SELECTED" : "MAIN_PLAYLIST_BUTTON", Layout.playlistButton, CGSize(width: 23, height: 12)),
            ("MAIN_CLUTTER_BAR_BUTTON_O", Layout.clutterButtonO, CGSize(width: 8, height: 8)),
            (alwaysOnTop ? "MAIN_CLUTTER_BAR_BUTTON_A_SELECTED" : "MAIN_CLUTTER_BAR_BUTTON_A", Layout.clutterButtonA, CGSize(width: 8, height: 7)),
            (trackInfo ? "MAIN_CLUTTER_BAR_BUTTON_I_SELECTED" : "MAIN_CLUTTER_BAR_BUTTON_I", Layout.clutterButtonI, CGSize(width: 8, height: 7)),
            (doubleSize ? "MAIN_CLUTTER_BAR_BUTTON_D_SELECTED" : "MAIN_CLUTTER_BAR_BUTTON_D", Layout.clutterButtonD, CGSize(width: 8, height: 8)),
            (video ? "MAIN_CLUTTER_BAR_BUTTON_V_SELECTED" : "MAIN_CLUTTER_BAR_BUTTON_V", Layout.clutterButtonV, CGSize(width: 8, height: 7)),
        ]
    }

    var body: some View {
        let coordinator = WindowCoordinatorBox.shared.value
        let sprites = Self.sprites(
            shuffle: audioPlayer.shuffleEnabled,
            repeatActive: audioPlayer.repeatMode.isActive,
            eqVisible: coordinator?.isEQWindowVisible ?? false,
            playlistVisible: coordinator?.isPlaylistWindowVisible ?? false,
            alwaysOnTop: settings.isAlwaysOnTop,
            trackInfo: settings.showTrackInfoDialog,
            doubleSize: settings.isDoubleSizeMode,
            video: settings.showVideoWindow
        )
        if let flattened = Self.flatten(sprites, from: skinManager.currentSkin) {
            Image(nsImage: flattened)
                .interpolation(.none)
                .antialiased(false)
                .resizable()
                .frame(width: WinampSizes.main.width, height: WinampSizes.main.height)
                .allowsHitTesting(false)
                .at(CGPoint(x: 0, y: 0))
        }
    }

    /// The sprite list rendered into one main-window-sized bitmap. Sprites the
    /// skin does not supply are skipped, leaving the background showing through.
    static func flatten(_ sprites: [(String, CGPoint, CGSize)], from skin: Skin?) -> NSImage? {
        guard let skin else { return nil }
        return SpriteCompositor.flatten(
            sprites.compactMap { name, origin, size in
                skin.images[name].map { (image: $0, origin: origin, size: size) }
            },
            into: WinampSizes.main
        )
    }
}
