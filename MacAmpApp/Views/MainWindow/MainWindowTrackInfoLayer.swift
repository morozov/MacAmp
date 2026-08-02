import SwiftUI

/// Track info display with scrolling text using TEXT.bmp character sprites.
/// Only re-evaluates when displayTitle or scrollOffset changes.
struct MainWindowTrackInfoLayer: View {
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    let interactionState: WinampMainWindowInteractionState

    private typealias Layout = WinampMainWindowLayout

    var body: some View {
        let baseText = playbackCoordinator.displayTitle.isEmpty ? "MacAmp" : playbackCoordinator.displayTitle
        let trackText = interactionState.transientMessage ?? baseText
        let textWidth = trackText.count * 5
        let displayWidth = Int(Layout.trackInfo.width)

        if textWidth > displayWidth {
            HStack(spacing: 0) {
                TrackInfoSprites(text: trackText)
                    .offset(x: interactionState.scrollOffset, y: -2)
                    .onAppear { interactionState.startScrolling() }
                    .onChange(of: playbackCoordinator.displayTitle) { _, _ in interactionState.resetScrolling() }
                    .onChange(of: interactionState.transientMessage) { _, _ in interactionState.resetScrolling() }
            }
            .frame(width: Layout.trackInfo.width, height: Layout.trackInfo.height)
            .clipped()
            .at(CGPoint(x: Layout.trackInfo.minX, y: Layout.trackInfo.minY))
        } else {
            TrackInfoSprites(text: trackText)
                .offset(y: -2)
                .frame(width: Layout.trackInfo.width, height: Layout.trackInfo.height, alignment: .leading)
                .at(CGPoint(x: Layout.trackInfo.minX, y: Layout.trackInfo.minY))
        }
    }
}

/// The row of TEXT.bmp glyphs flattened into a single bitmap instead of one
/// `Image`/`CALayer` per character. The former `HStack` of ~30 sprite views made
/// a marquee scroll re-commit ~30 layers each 6.7 Hz tick; this commits one.
///
/// Sized `count*5 × 6` — identical to the former HStack — so the caller's
/// `.offset` / `.frame` / `.clipped` positioning is byte-for-byte unchanged;
/// only the leaf rendering differs. Each glyph occupies 5×6 at `x = index*5`.
struct TrackInfoSprites: View {
    @Environment(SkinManager.self) private var skinManager
    let text: String

    /// Sprite key for one character, matching `SkinSprites.generateTextSprites`
    /// (lowercase code points). Uppercase letters fold to their lowercase key;
    /// non-ASCII falls back to space. Static so tests can assert it directly.
    static func spriteName(for character: Character) -> String {
        let code: UInt8
        if let ascii = character.asciiValue {
            code = character.isLetter && character.isUppercase ? ascii + 32 : ascii
        } else {
            code = 32
        }
        return "CHARACTER_\(code)"
    }

    /// Ordered sprite keys for the text, one per rendered glyph.
    static func glyphNames(for text: String) -> [String] {
        text.uppercased().map(spriteName(for:))
    }

    var body: some View {
        let size = CGSize(width: CGFloat(Self.glyphNames(for: text).count) * 5, height: 6)
        if let flattened = Self.flatten(text, from: skinManager.currentSkin) {
            Image(nsImage: flattened)
                .interpolation(.none)
                .antialiased(false)
                .resizable()
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
        } else {
            Color.clear.frame(width: size.width, height: size.height)
        }
    }

    /// The text rendered into one `count*5 × 6` bitmap. Glyphs the skin does not
    /// supply are skipped, leaving their cell transparent.
    static func flatten(_ text: String, from skin: Skin?) -> NSImage? {
        guard let skin else { return nil }
        let names = glyphNames(for: text)
        return SpriteCompositor.flatten(
            names.enumerated().compactMap { index, name in
                skin.images[name].map {
                    (image: $0,
                     origin: CGPoint(x: CGFloat(index) * 5, y: 0),
                     size: CGSize(width: 5, height: 6))
                }
            },
            into: CGSize(width: CGFloat(names.count) * 5, height: 6)
        )
    }
}
