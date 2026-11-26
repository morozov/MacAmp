import AppKit
import SwiftUI
import Testing
@testable import MacAmp

@MainActor
@Suite("Skinned tooltip propagation")
struct SkinnedTooltipTests {
    @Test("Row updates retain the hit owner and replace its callbacks and tooltip")
    func rowUpdates() throws {
        let view = ClickCatcherNSView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        let point = NSPoint(x: 5, y: 5)
        let owner = try #require(view.hitTest(point))
        var received: [CGFloat] = []
        var doubleClicks = 0
        var drags: [CGFloat] = []
        var releases: [CGFloat] = []
        let firstHelp = "Select the first row"
        let first = ClickCatcherView(
            onSingleClick: { received.append($0 + $1) },
            onDoubleClick: { doubleClicks += 1 },
            help: firstHelp,
            onDrag: { drags.append($0) },
            onMouseUp: { releases.append($0) }
        )
        first.configure(view)
        #expect(view.toolTip == firstHelp)
        #expect(view.hitTest(point) === owner)
        view.onSingleClick?(2, 3)
        view.onDoubleClick?()
        view.onDrag?(7)
        view.onMouseUp?(9)
        #expect(received == [5])
        #expect(doubleClicks == 1)
        #expect(drags == [7])
        #expect(releases == [9])

        let nextHelp = "Select the replacement row"
        let next = ClickCatcherView(
            onSingleClick: { received.append($0 * $1) },
            onDoubleClick: { doubleClicks += 10 },
            help: nextHelp
        )
        next.configure(view)
        #expect(view.toolTip == nextHelp)
        #expect(view.hitTest(point) === owner)
        view.onSingleClick?(2, 3)
        view.onDoubleClick?()
        view.onDrag?(11)
        view.onMouseUp?(13)
        #expect(received == [5, 6])
        #expect(doubleClicks == 11)
        #expect(drags == [7])
        #expect(releases == [9])
        #expect(view.window == nil)
        #expect(view.subviews.isEmpty)
    }

    @Test("Titlebar help stays on the existing native drag owner",
          arguments: [WindowKind.main, .equalizer, .playlist, .video, .milkdrop])
    func titlebarOwner(_ kind: WindowKind) throws {
        let view = TitlebarDragCaptureNSView(windowKind: kind)
        view.frame = NSRect(x: 0, y: 0, width: 100, height: 14)
        #expect(view.windowKind == kind)
        #expect(view.hitTest(NSPoint(x: 5, y: 5)) === view)
        #expect(!(try #require(view.toolTip)).isEmpty)
        #expect(view.initialMouseLocation == .zero)
        #expect(!view.isDragging)
        #expect(view.window == nil)
        #expect(view.subviews.isEmpty)
    }

    @Test("Spectrum updates preserve its native owner and providers while replacing help")
    func spectrumUpdates() {
        let view = SpectrumAnalyzerNSView(frame: NSRect(x: 0, y: 0, width: 76, height: 16))
        let firstHelp = "Choose another mode"
        let first = SpectrumAnalyzerLayer(colors: [.red], bands: { [1, 2] }, isRendering: { true }, help: firstHelp)
        first.configure(view)
        #expect(view.toolTip == firstHelp)
        #expect(view.bandsProvider?() == [1, 2])
        #expect(view.isRenderingProvider?() == true)
        let colors = view.colors
        let owner = view.hitTest(NSPoint(x: 5, y: 5))

        let nextHelp = "Choose a different mode"
        let next = SpectrumAnalyzerLayer(colors: [.red], bands: { [3] }, isRendering: { false }, help: nextHelp)
        next.configure(view)
        #expect(view.toolTip == nextHelp)
        #expect(view.bandsProvider?() == [3])
        #expect(view.isRenderingProvider?() == false)
        #expect(view.colors == colors)
        #expect(view.hitTest(NSPoint(x: 5, y: 5)) === owner)
        #expect(view.window == nil)
        #expect(view.subviews.isEmpty)
    }
}
