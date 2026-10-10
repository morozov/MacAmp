import AppKit
import Foundation
import Testing
@testable import MacAmp

@MainActor
@Suite("Playlist row dragging")
struct PlaylistRowDragTests {
    private let rowHeight = PlaylistWindowSizeState.trackRowHeight

    private func controller(_ count: Int) -> PlaylistController {
        let controller = PlaylistController()
        for n in 0..<count {
            controller.addTrack(Track(url: URL(fileURLWithPath: "/tmp/\(n).mp3"), title: "\(n)", artist: "", duration: 1))
        }
        return controller
    }

    private func titles(_ controller: PlaylistController) -> [String] {
        controller.playlist.map(\.title)
    }

    @Test("Selected tracks move one row and keep the gaps between them")
    func movesKeepingGaps() {
        let playlist = controller(6)
        #expect(playlist.moveTracks(at: [1, 3], by: 1))
        #expect(titles(playlist) == ["0", "2", "1", "4", "3", "5"])
        #expect(playlist.moveTracks(at: [2, 4], by: -1))
        #expect(titles(playlist) == ["0", "1", "2", "3", "4", "5"])
    }

    @Test("A selected track at the edge blocks the move", arguments: [(Set([0, 2]), -1), (Set([3, 5]), 1)])
    func edgeBlocks(indices: Set<Int>, step: Int) {
        let playlist = controller(6)
        #expect(!playlist.moveTracks(at: indices, by: step))
        #expect(titles(playlist) == ["0", "1", "2", "3", "4", "5"])
    }

    @Test("The current track keeps its position marker when moved or displaced")
    func currentTrackFollows() {
        let playlist = controller(4)
        playlist.updatePosition(with: playlist.playlist[2])
        // Positions are 1-based: the current track starts third.
        playlist.moveTracks(at: [1], by: 1)
        #expect(playlist.currentPosition == 2)
        playlist.moveTracks(at: [1], by: 1)
        #expect(playlist.currentPosition == 3)
    }

    @Test("Dragging moves the selection one row per row crossed")
    func dragFollowsPointer() {
        let state = PlaylistWindowInteractionState()
        state.selectedIndices = [1, 3]
        var steps: [Int] = []
        state.pressRow(index: 1, yFromTop: 2, windowY: 500)
        #expect(state.selectedIndices == [1, 3], "a press on a selected row keeps the selection")

        state.dragRows(windowY: 500 - 2 * rowHeight, viewportHeight: 200, maxScroll: 0) { _, step in
            steps.append(step)
            return true
        }
        #expect(steps == [1, 1])
        #expect(state.selectedIndices == [3, 5])
        #expect(state.anchorIndex == 3)

        state.releaseRow(windowY: 500 - 2 * rowHeight)
        #expect(state.selectedIndices == [3], "release narrows the selection to the row under the pointer")
    }

    @Test("Rows crossed while a move is blocked still count when the pointer returns")
    func blockedRowsStillCount() {
        let state = PlaylistWindowInteractionState()
        state.pressRow(index: 0, yFromTop: 2, windowY: 500)
        // Up past the top: the first track cannot move, but the row is counted.
        state.dragRows(windowY: 500 + rowHeight, viewportHeight: 200, maxScroll: 0) { _, _ in false }
        #expect(state.selectedIndices == [0])

        var steps: [Int] = []
        state.dragRows(windowY: 500 - rowHeight, viewportHeight: 200, maxScroll: 0) { _, step in
            steps.append(step)
            return true
        }
        #expect(steps == [1, 1])
        #expect(state.selectedIndices == [2])
    }

    @Test("A cancelled press ignores the rest of the drag and the release")
    func cancelledDragIsInert() {
        let state = PlaylistWindowInteractionState()
        state.selectedIndices = [1, 2]
        state.pressRow(index: 1, yFromTop: 2, windowY: 500)
        state.cancelRowDrag()
        state.dragRows(windowY: 500 - rowHeight, viewportHeight: 200, maxScroll: 0) { _, _ in
            Issue.record("a cancelled drag must not move tracks")
            return true
        }
        state.releaseRow(windowY: 500)
        #expect(state.selectedIndices == [1, 2])
    }

    @Test("Dragging past the bottom of the list scrolls it one row")
    func dragScrolls() {
        let state = PlaylistWindowInteractionState()
        state.pressRow(index: 0, yFromTop: 2, windowY: 500)
        state.dragRows(windowY: 500 - 20 * rowHeight, viewportHeight: 5 * rowHeight, maxScroll: 100) { _, _ in true }
        #expect(state.scrollOffsetPixels == rowHeight)
    }

    @Test("A row reports where it was pressed, then the pointer height while dragged and on release")
    func clickCatcherForwardsDrag() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered, defer: true)
        let view = ClickCatcherNSView(frame: NSRect(x: 0, y: 40, width: 100, height: 20))
        window.contentView?.addSubview(view)
        var events: [String] = []
        view.onSingleClick = { events.append("press \($0) \($1)") }
        view.onDrag = { events.append("drag \($0)") }
        view.onMouseUp = { events.append("up \($0)") }

        func event(_ type: NSEvent.EventType, y: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 10, y: y), modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, y: 55))
        view.mouseDragged(with: try event(.leftMouseDragged, y: 30))
        view.mouseUp(with: try event(.leftMouseUp, y: 30))
        #expect(events == ["press 5.0 55.0", "drag 30.0", "up 30.0"])
    }
}
