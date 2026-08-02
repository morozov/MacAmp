import Testing
import Foundation
import SwiftUI
import AppKit
import CoreGraphics
@testable import MacAmp

/// Correctness of collapsing the main-window button sprites (titlebar,
/// transport, shuffle/repeat, EQ/PL toggles, clutter) into one `Canvas`.
/// Asserts the state→sprite selection and that the Canvas rendering is
/// pixel-identical to the former per-button `SimpleSpriteImage` views.
@MainActor
@Suite("Main-window button sprites", .tags(.skin))
struct ButtonSpritesRenderingTests {

    // MARK: - State → sprite selection

    @Test("Selected states pick the *_SELECTED sprite")
    func selectionReflectsState() {
        let off = MainWindowButtonSprites.sprites(
            shuffle: false, repeatActive: false, eqVisible: false, playlistVisible: false,
            alwaysOnTop: false, trackInfo: false, doubleSize: false, video: false)
        let on = MainWindowButtonSprites.sprites(
            shuffle: true, repeatActive: true, eqVisible: true, playlistVisible: true,
            alwaysOnTop: true, trackInfo: true, doubleSize: true, video: true)

        let offKeys = Set(off.map(\.0))
        let onKeys = Set(on.map(\.0))
        #expect(offKeys.contains("MAIN_SHUFFLE_BUTTON") && !offKeys.contains("MAIN_SHUFFLE_BUTTON_SELECTED"))
        #expect(onKeys.contains("MAIN_SHUFFLE_BUTTON_SELECTED") && !onKeys.contains("MAIN_SHUFFLE_BUTTON"))
        #expect(onKeys.contains("MAIN_REPEAT_BUTTON_SELECTED"))
        #expect(onKeys.contains("MAIN_EQ_BUTTON_SELECTED"))
        #expect(onKeys.contains("MAIN_PLAYLIST_BUTTON_SELECTED"))
        #expect(onKeys.contains("MAIN_CLUTTER_BAR_BUTTON_A_SELECTED"))
        #expect(onKeys.contains("MAIN_CLUTTER_BAR_BUTTON_D_SELECTED"))
        #expect(onKeys.contains("MAIN_CLUTTER_BAR_BUTTON_V_SELECTED"))
        // Fixed buttons appear regardless of state.
        #expect(offKeys.contains("MAIN_PLAY_BUTTON") && offKeys.contains("MAIN_EJECT_BUTTON"))
        #expect(off.count == 18 && on.count == 18)
    }

    // MARK: - Pixel identity: Canvas vs per-sprite views

    @Test("Button Canvas is pixel-identical to per-sprite views", .timeLimit(.minutes(1)))
    func canvasMatchesSpriteViews() async throws {
        let skin = try await loadWinampSkin()
        // A representative mix of selected/unselected states.
        let list = MainWindowButtonSprites.sprites(
            shuffle: true, repeatActive: false, eqVisible: true, playlistVisible: false,
            alwaysOnTop: true, trackInfo: false, doubleSize: false, video: true)

        let size = CGSize(width: WinampSizes.main.width, height: WinampSizes.main.height)
        let canvasImage = try render(SpriteCanvas(list: list).environment(skin), size: size)
        let viewsImage = try render(SpriteViews(list: list).environment(skin), size: size)

        #expect(canvasImage.width == viewsImage.width && canvasImage.height == viewsImage.height)
        let a = try #require(rgbaBytes(canvasImage))
        let b = try #require(rgbaBytes(viewsImage))
        #expect(a == b, "button Canvas rendering differs from per-sprite views")
    }

    /// The production flattening, presented the way `MainWindowButtonSprites`
    /// presents it.
    private struct SpriteCanvas: View {
        @Environment(SkinManager.self) private var skinManager
        let list: [(String, CGPoint, CGSize)]
        var body: some View {
            if let flattened = MainWindowButtonSprites.flatten(list, from: skinManager.currentSkin) {
                Image(nsImage: flattened)
                    .interpolation(.none)
                    .antialiased(false)
                    .resizable()
                    .frame(width: WinampSizes.main.width, height: WinampSizes.main.height)
            }
        }
    }

    /// The former per-button rendering: one `SimpleSpriteImage` at each position.
    private struct SpriteViews: View {
        let list: [(String, CGPoint, CGSize)]
        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(Array(list.enumerated()), id: \.offset) { _, entry in
                    SimpleSpriteImage(entry.0, width: entry.2.width, height: entry.2.height)
                        .at(entry.1)
                }
            }
            .frame(width: WinampSizes.main.width, height: WinampSizes.main.height, alignment: .topLeading)
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

    private func render<V: View>(_ view: V, size: CGSize) throws -> CGImage {
        let renderer = ImageRenderer(content:
            view.frame(width: size.width, height: size.height).background(Color.black)
        )
        renderer.scale = 1
        return try #require(renderer.cgImage, "ImageRenderer produced no image")
    }

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
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
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
