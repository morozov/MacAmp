import Foundation
import Testing
@testable import MacAmp

@MainActor
@Suite("Marquee dragging")
struct MarqueeDragTests {
    private let longTitle = String(repeating: "X", count: 40)  // 200 px, wider than the 152 px display

    private func state(title: String) -> WinampMainWindowInteractionState {
        let state = WinampMainWindowInteractionState()
        state.displayTitleProvider = { title }
        return state
    }

    @Test("A long title follows the pointer")
    func longTitleFollowsPointer() {
        let state = state(title: longTitle)
        state.dragMarquee(to: -10)
        state.dragMarquee(to: -25)
        #expect(state.scrollOffset == -25)
        state.dragMarquee(to: -5)
        #expect(state.scrollOffset == -5)
    }

    @Test("A title that fits the display does not move")
    func shortTitleStaysPut() {
        let state = state(title: "Short")
        state.dragMarquee(to: -30)
        #expect(state.scrollOffset == 0)
    }

    @Test("Each drag starts from where the text was left")
    func dragsAccumulate() {
        let state = state(title: longTitle)
        state.dragMarquee(to: -20)
        state.endMarqueeDrag()
        state.dragMarquee(to: -10)
        #expect(state.scrollOffset == -30)
        state.cleanup()
    }

    @Test("Offsets wrap within one loop of the title and its separator",
          arguments: [(CGFloat(-235), CGFloat(0)), (-236, -1), (5, -230), (-100, -100), (0, 0)])
    func wraps(offset: CGFloat, expected: CGFloat) {
        // A 200 px title plus the 35 px separator loops every 235 px.
        #expect(WinampMainWindowInteractionState.wrappedOffset(offset, textWidth: 200) == expected)
    }

    @Test("A long title is drawn twice around the separator; a short one once")
    func marqueeText() {
        #expect(WinampMainWindowInteractionState.marqueeText(for: longTitle) == longTitle + "  ***  " + longTitle)
        #expect(WinampMainWindowInteractionState.marqueeText(for: "Short") == "Short")
    }
}
