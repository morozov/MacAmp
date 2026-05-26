import SwiftUI
import AppKit

/// Bitmap text renderer using TEXT.BMP glyphs; uses `fallbackColor` for missing glyphs.
struct PlaylistBitmapText: View {
    @Environment(SkinManager.self) var skinManager

    let text: String
    let fallbackColor: Color
    let spacing: CGFloat
    let fallbackSize: CGFloat
    let fallbackDesign: Font.Design

    init(
        _ text: String,
        fallbackColor: Color,
        spacing: CGFloat = 1,
        fallbackSize: CGFloat = 9,
        fallbackDesign: Font.Design = .default
    ) {
        self.text = text
        self.fallbackColor = fallbackColor
        self.spacing = spacing
        self.fallbackSize = fallbackSize
        self.fallbackDesign = fallbackDesign
    }

    private func imageForChar(_ ch: Character) -> NSImage? {
        // TEXT.BMP only contains lowercase glyphs (see `SkinSprites.fontLookup`
        // row 0: "abcdefghijklmnopqrstuvwxyz…"). Webamp folds the character
        // through `deburr(char).toLowerCase().charCodeAt(0)` before mapping
        // (`packages/webamp/js/components/Character.tsx`), so 'M' and 'É'
        // both resolve to the lowercase-letter sprite. Match that — without
        // it, every uppercase letter misses the lookup and falls back to the
        // system font, making the rendering inconsistent with the main
        // window's track-info area (which strips case via its own +32
        // ASCII-offset trick).
        let folded = String(ch)
            .folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()
        let code = folded.utf16.first ?? 32
        let key = "CHARACTER_\(code)"
        return skinManager.currentSkin?.images[key]
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, ch in
                if let img = imageForChar(ch) {
                    Image(nsImage: img)
                        .interpolation(.none)
                        .antialiased(false)
                        .resizable()
                        .frame(width: img.size.width, height: img.size.height)
                } else {
                    Text(String(ch))
                        .font(.system(size: fallbackSize, design: fallbackDesign))
                        .foregroundColor(fallbackColor)
                }
            }
        }
    }
}
