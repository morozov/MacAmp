import SwiftUI

/// Shade and close are part of the titlebar bitmap; only the pressed sprite is drawn.
struct PlaylistTitleBarButtons: View {
    @Environment(UserActionDispatcher.self) private var dispatcher

    let windowWidth: CGFloat
    let shaded: Bool

    var body: some View {
        let buttonY: CGFloat = 7.5

        SkinHitButton(pressedSprite: shaded ? "PLAYLIST_EXPAND_SELECTED" : "PLAYLIST_COLLAPSE_SELECTED",
                      width: 9, height: 9) { dispatcher.perform(.shadePlaylistWindow) }
            .position(x: windowWidth - 16.5, y: buttonY)

        SkinHitButton(pressedSprite: "PLAYLIST_CLOSE_SELECTED", width: 9, height: 9) { dispatcher.perform(.togglePlaylistWindow) }
            .position(x: windowWidth - 6.5, y: buttonY)
    }
}
