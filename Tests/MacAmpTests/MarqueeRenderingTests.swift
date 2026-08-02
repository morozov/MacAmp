import Testing
import Foundation
import SwiftUI
import AppKit
import CoreGraphics
@testable import MacAmp

/// Correctness of the main-window marquee's migration from ~30 per-character
/// `Image`/`CALayer` sprites to a single `Canvas`. Asserts the two renderings
/// are equivalent — by construction (mapping + 5×6 glyphs) and by pixels.
@MainActor
@Suite("Marquee rendering", .tags(.skin))
struct MarqueeRenderingTests {

    // MARK: - Glyph key mapping

    @Test("Glyph keys fold uppercase to lowercase code points and match sprite names")
    func glyphNamesMapCorrectly() {
        #expect(TrackInfoSprites.spriteName(for: "A") == "CHARACTER_97")   // 'a'
        #expect(TrackInfoSprites.spriteName(for: "a") == "CHARACTER_97")
        #expect(TrackInfoSprites.spriteName(for: "Z") == "CHARACTER_122")  // 'z'
        #expect(TrackInfoSprites.spriteName(for: "5") == "CHARACTER_53")
        #expect(TrackInfoSprites.spriteName(for: " ") == "CHARACTER_32")
        #expect(TrackInfoSprites.spriteName(for: "é") == "CHARACTER_32")   // non-ASCII → space
        #expect(TrackInfoSprites.glyphNames(for: "Ab 5") ==
                ["CHARACTER_97", "CHARACTER_98", "CHARACTER_32", "CHARACTER_53"])
    }

    // MARK: - Glyph sprites are 5×6 (why Canvas draw == the former Image fill)

    @Test("Bundled skin TEXT glyphs are exactly 5×6", .timeLimit(.minutes(1)))
    func glyphSpritesAre5x6() async throws {
        let skin = try await loadWinampSkin()
        let images = try #require(skin.currentSkin?.images)
        // The marquee draws each glyph into a 5×6 rect; the source sprite must be
        // 5×6 so `Canvas.draw(in: 5×6)` matches the former `Image().frame(5, 6)`.
        for name in TrackInfoSprites.glyphNames(for: "abcdefghijklmnopqrstuvwxyz0123456789 .:()-") {
            let image = try #require(images[name], "missing sprite \(name)")
            #expect(image.size.width == 5 && image.size.height == 6, "\(name) is \(image.size)")
        }
    }

    // MARK: - Pixel identity: old per-sprite HStack vs new Canvas

    @Test("Canvas marquee is pixel-identical to the per-sprite HStack", .timeLimit(.minutes(1)))
    func canvasMatchesSpriteHStack() async throws {
        let skin = try await loadWinampSkin()
        let text = "THE LIFE IMPOSSIBLE 086"
        let width = CGFloat(text.uppercased().count) * 5

        let newImage = try render(TrackInfoSprites(text: text).environment(skin), width: width, height: 6)
        let oldImage = try render(OldMarqueeSprites(text: text).environment(skin), width: width, height: 6)

        #expect(newImage.width == oldImage.width && newImage.height == oldImage.height,
                "sizes differ: new \(newImage.width)×\(newImage.height) vs old \(oldImage.width)×\(oldImage.height)")
        let newBytes = try #require(rgbaBytes(newImage))
        let oldBytes = try #require(rgbaBytes(oldImage))
        #expect(newBytes == oldBytes, "Canvas rendering differs from the sprite HStack")
    }

    /// The former rendering: one `SimpleSpriteImage` per character in an HStack.
    private struct OldMarqueeSprites: View {
        let text: String
        var body: some View {
            HStack(spacing: 0) {
                ForEach(Array(text.uppercased().enumerated()), id: \.offset) { _, character in
                    SimpleSpriteImage(TrackInfoSprites.spriteName(for: character), width: 5, height: 6)
                }
            }
        }
    }

    // MARK: - Helpers

    private func loadWinampSkin() async throws -> SkinManager {
        let manager = SkinManager()
        manager.loadSkin(from: try bundledSkinURL(named: "Winamp"))
        let deadline = Date().addingTimeInterval(5)
        while manager.isLoading {
            if Date() > deadline { throw Failure("SkinManager load timed out") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return manager
    }

    private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(content:
            view.frame(width: width, height: height).background(Color.black)
        )
        renderer.scale = 1
        return try #require(renderer.cgImage, "ImageRenderer produced no image")
    }

    /// Rasterize into a fixed RGBA8 buffer so two images compare byte-for-byte
    /// regardless of their source pixel format.
    private func rgbaBytes(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = bytes.withUnsafeMutableBytes({ raw in
            CGContext(data: raw.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info)
        }) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    private func bundledSkinURL(named name: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MacAmpTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let url = root.appendingPathComponent("MacAmpApp/Skins/\(name).wsz")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure("Missing bundled skin at \(url.path)")
        }
        return url
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }
}
