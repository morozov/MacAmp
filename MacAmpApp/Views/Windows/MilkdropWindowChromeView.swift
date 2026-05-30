import SwiftUI

/// Milkdrop Window - Pixel-perfect GEN.bmp chrome using dynamic layout
/// Matches Main/EQ/Playlist/Video pattern: ZStack + SimpleSpriteImage + .at()
///
/// Titlebar has 7 sections with gold fillers that expand symmetrically:
/// LEFT_CAP(25) + LEFT_GOLD(n×25) + LEFT_END(25) + CENTER(3×25=75) + RIGHT_END(25) + RIGHT_GOLD(n×25) + RIGHT_CAP(25)
struct MilkdropWindowChromeView<Content: View>: View {
    /// Size state for dynamic layout (segment-based resizing)
    let sizeState: MilkdropWindowSizeState
    @ViewBuilder let content: Content

    // MARK: - Resize Gesture State
    @State private var dragStartSize: Size2D?
    @State private var isDragging: Bool = false
    @State private var resizePreview = WindowResizePreviewOverlay()

    // MARK: - Environment
    @Environment(WindowFocusState.self) private var windowFocusState
    @Environment(ButterchurnBridge.self) private var bridge
    @Environment(UserActionDispatcher.self) private var dispatcher
    @Environment(SkinManager.self) private var skinManager

    private var isWindowActive: Bool { windowFocusState.isMilkdropKey }

    /// Pixel dimensions from sizeState
    private var pixelSize: CGSize { sizeState.pixelSize }

    /// Content area dimensions for WKWebView
    private var contentSize: CGSize { sizeState.contentSize }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background
            Color.black
                .frame(width: pixelSize.width, height: pixelSize.height)

            // Dynamic titlebar
            buildDynamicTitlebar()

            // Dynamic side borders
            buildDynamicBorders()

            // Content area (WKWebView for Butterchurn)
            content
                .frame(width: contentSize.width, height: contentSize.height)
                .position(x: pixelSize.width / 2, y: 20 + contentSize.height / 2)

            // Dynamic bottom bar
            buildDynamicBottomBar()

            // Close button (X) — overlay over the close glyph baked into the
            // GEN_TOP_RIGHT sprite. Position mirrors the playlist's close
            // button (`PlaylistTitleBarButtons`): 9×9, x = right − 11, y = 7.
            Button(action: { dispatcher.perform(.toggleMilkdropWindow) }, label: {
                Color.clear.frame(width: 9, height: 9).contentShape(Rectangle())
            })
            .buttonStyle(.plain)
            .focusable(false)
            .position(x: pixelSize.width - 6.5, y: 7.5)

            // Resize handle (bottom-right corner)
            buildResizeHandle()
        }
        .frame(width: pixelSize.width, height: pixelSize.height, alignment: .topLeading)
        .fixedSize()
        .background(Color.black)
    }

    // MARK: - Dynamic Titlebar (7 sections)

    @ViewBuilder
    private func buildDynamicTitlebar() -> some View {
        let suffix = isWindowActive ? "_SELECTED" : ""
        let goldTiles = sizeState.goldFillerTilesPerSide
        let centerStart = sizeState.centerSectionStartX

        WinampTitlebarDragHandle(windowKind: .milkdrop, size: CGSize(width: pixelSize.width, height: 20)) {
            ZStack(alignment: .topLeading) {
                // Section 1: Left cap (25px)
                SimpleSpriteImage("GEN_TOP_LEFT\(suffix)", width: 25, height: 20)
                    .position(x: 12.5, y: 10)

                // Section 2: Left gold bar tiles (dynamic count)
                ForEach(0..<goldTiles, id: \.self) { i in
                    SimpleSpriteImage("GEN_TOP_LEFT_RIGHT_FILL\(suffix)", width: 25, height: 20)
                        .position(x: 25 + 12.5 + CGFloat(i) * 25, y: 10)
                }

                // Section 3: Left end (25px)
                SimpleSpriteImage("GEN_TOP_LEFT_END\(suffix)", width: 25, height: 20)
                    .position(x: centerStart - 12.5, y: 10)

                // Section 4: Center grey tiles (fixed 3 tiles = 75px)
                ForEach(0..<sizeState.centerGreyTileCount, id: \.self) { i in
                    SimpleSpriteImage("GEN_TOP_CENTER_FILL\(suffix)", width: 25, height: 20)
                        .position(x: centerStart + 12.5 + CGFloat(i) * 25, y: 10)
                }

                // Section 5: Right end (25px)
                SimpleSpriteImage("GEN_TOP_RIGHT_END\(suffix)", width: 25, height: 20)
                    .position(x: centerStart + 75 + 12.5, y: 10)

                // Section 6: Right gold bar tiles (symmetric with left)
                ForEach(0..<goldTiles, id: \.self) { i in
                    SimpleSpriteImage("GEN_TOP_LEFT_RIGHT_FILL\(suffix)", width: 25, height: 20)
                        .position(x: centerStart + 75 + 25 + 12.5 + CGFloat(i) * 25, y: 10)
                }

                // Section 7: Right cap with close button (25px)
                SimpleSpriteImage("GEN_TOP_RIGHT\(suffix)", width: 25, height: 20)
                    .position(x: pixelSize.width - 12.5, y: 10)

                // MILKDROP HD letters - centered in 75px center section
                milkdropLetters
                    .position(x: sizeState.milkdropLettersCenterX, y: 8)
            }
        }
        .position(x: pixelSize.width / 2, y: 10)
    }

    // MARK: - Dynamic Borders

    @ViewBuilder
    private func buildDynamicBorders() -> some View {
        let tileCount = sizeState.verticalBorderTileCount

        ForEach(0..<tileCount, id: \.self) { i in
            // Left border (11px wide)
            SimpleSpriteImage("GEN_MIDDLE_LEFT", width: 11, height: 29)
                .position(x: 5.5, y: 20 + 14.5 + CGFloat(i) * 29)

            // Right border (8px wide)
            SimpleSpriteImage("GEN_MIDDLE_RIGHT", width: 8, height: 29)
                .position(x: pixelSize.width - 4, y: 20 + 14.5 + CGFloat(i) * 29)
        }
    }

    // MARK: - Dynamic Bottom Bar

    @ViewBuilder
    private func buildDynamicBottomBar() -> some View {
        let bottomBarY = pixelSize.height - 7  // 14px bar, center at 7

        // LEFT section (125px fixed)
        SimpleSpriteImage("GEN_BOTTOM_LEFT", width: 125, height: 14)
            .position(x: 62.5, y: bottomBarY)

        // CENTER section (dynamic tiles) - TWO-PIECE sprites (13px + 1px = 14px)
        let centerCount = sizeState.centerTileCount
        ForEach(0..<centerCount, id: \.self) { i in
            VStack(spacing: 0) {
                SimpleSpriteImage("GEN_BOTTOM_FILL_TOP", width: 25, height: 13)
                SimpleSpriteImage("GEN_BOTTOM_FILL_BOTTOM", width: 25, height: 1)
            }
            .position(x: 125 + 12.5 + CGFloat(i) * 25, y: bottomBarY)
        }

        // RIGHT section (125px fixed) - contains resize corner
        SimpleSpriteImage("GEN_BOTTOM_RIGHT", width: 125, height: 14)
            .position(x: pixelSize.width - 62.5, y: bottomBarY)
    }

    // MARK: - Resize Handle

    @ViewBuilder
    private func buildResizeHandle() -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Capture start size on first drag tick
                        if dragStartSize == nil {
                            dragStartSize = sizeState.size
                            isDragging = true
                            WindowSnapManager.shared.beginProgrammaticAdjustment()
                        }

                        guard let baseSize = dragStartSize else { return }

                        // Calculate quantized size from drag delta (25px width, 29px height segments)
                        let widthDelta = Int(round(value.translation.width / 25))
                        let heightDelta = Int(round(value.translation.height / 29))

                        let candidate = Size2D(
                            width: max(0, baseSize.width + widthDelta),
                            height: max(0, baseSize.height + heightDelta)
                        )

                        // Show AppKit preview overlay
                        if let coordinator = WindowCoordinator.shared,
                           let window = coordinator.milkdropWindow {
                            resizePreview.show(in: window, previewSize: candidate.toPixels())
                        }
                    }
                    .onEnded { value in
                        guard let baseSize = dragStartSize else { return }

                        let widthDelta = Int(round(value.translation.width / 25))
                        let heightDelta = Int(round(value.translation.height / 29))

                        let finalSize = Size2D(
                            width: max(0, baseSize.width + widthDelta),
                            height: max(0, baseSize.height + heightDelta)
                        )

                        // Commit size change
                        sizeState.size = finalSize

                        // Sync NSWindow with top-left anchoring
                        if let coordinator = WindowCoordinator.shared {
                            coordinator.updateMilkdropWindowSize(to: sizeState.pixelSize)
                        }

                        // Hide preview
                        resizePreview.hide()

                        // Notify Butterchurn of canvas resize
                        bridge.setSize(width: contentSize.width, height: contentSize.height)

                        // Cleanup
                        isDragging = false
                        dragStartSize = nil
                        WindowSnapManager.shared.endProgrammaticAdjustment()
                    }
            )
            .position(x: pixelSize.width - 10, y: pixelSize.height - 10)
    }

    /// MILKDROP HD letters HStack — letter widths come from `Skin.genLetterWidths`,
    /// populated at skin-load time by `SkinManager.extractGenTextLetters`. The
    /// inter-word space (5 px) is fixed; letter-to-letter spacing is zero,
    /// matching Webamp's `gen-text-letter` CSS.
    private var milkdropLetters: some View {
        HStack(spacing: 0) {
            ForEach(Array("MILKDROP HD".enumerated()), id: \.offset) { _, char in
                if char == " " {
                    Color.clear.frame(width: 5, height: 7)
                } else {
                    makeLetter(String(char))
                }
            }
        }
    }

    /// Renders a single GEN letter as one 7-tall sprite. Width is dynamic per
    /// skin (proportional font); falls back to a generous 8 px if a skin's
    /// GEN.bmp lacks a usable letter strip.
    @ViewBuilder
    private func makeLetter(_ letter: String) -> some View {
        let prefix = isWindowActive ? "GEN_TEXT_SELECTED_" : "GEN_TEXT_"
        let name = "\(prefix)\(letter)"
        let width = skinManager.currentSkin?.genLetterWidths[name] ?? 8
        SimpleSpriteImage(name, width: width, height: 7)
    }
}
