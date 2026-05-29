import SwiftUI

struct PlaylistTitleBarButtons: View {
    @Environment(UserActionDispatcher.self) private var dispatcher

    let windowWidth: CGFloat

    var body: some View {
        let buttonY: CGFloat = 7.5

        Button(action: { dispatcher.perform(.shadePlaylistWindow) }, label: {
            SimpleSpriteImage("MAIN_SHADE_BUTTON", width: 9, height: 9)
        })
        .buttonStyle(.plain)
        .focusable(false)
        .position(x: windowWidth - 16.5, y: buttonY)

        Button(action: { dispatcher.perform(.togglePlaylistWindow) }, label: {
            SimpleSpriteImage("MAIN_CLOSE_BUTTON", width: 9, height: 9)
        })
        .buttonStyle(.plain)
        .focusable(false)
        .position(x: windowWidth - 6.5, y: buttonY)
    }
}
