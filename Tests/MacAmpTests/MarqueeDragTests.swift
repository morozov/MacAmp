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

    @Test("Dragging past either end wraps around the auto-scroll cycle",
          arguments: [(CGFloat(-221), CGFloat(151)), (153, -219), (-100, -100)])
    func wraps(offset: CGFloat, expected: CGFloat) {
        // Text 200 px wide on a 152 px display cycles from 152 down to -220.
        #expect(WinampMainWindowInteractionState.wrappedOffset(offset, textWidth: 200, displayWidth: 152) == expected)
    }
}
