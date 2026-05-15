import SwiftUI
import AppKit

/// Time display in the playlist info bar.
struct PlaylistTimeText: View {
    @Environment(SkinManager.self) var skinManager

    let text: String
    let spacing: CGFloat

    init(_ text: String, spacing: CGFloat = 1) {
        self.text = text
        self.spacing = spacing
    }

    private var fallbackColor: Color {
        skinManager.currentSkin?.playlistStyle.normalTextColor ?? Color(red: 0, green: 1.0, blue: 0)
    }

    var body: some View {
        PlaylistBitmapText(
            text,
            fallbackColor: fallbackColor,
            spacing: spacing,
            fallbackSize: 8,
            fallbackDesign: Font.Design.monospaced
        )
    }
}

#Preview {
    ZStack {
        Color.black
        VStack(spacing: 10) {
            PlaylistTimeText("12:34 / 56:78")
            PlaylistTimeText("-9:87")
            PlaylistTimeText(":")
        }
    }
    .frame(width: 200, height: 100)
    .environment(SkinManager())
}
