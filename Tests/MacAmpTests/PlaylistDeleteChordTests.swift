import Testing
import AppKit
@testable import MacAmp

/// In-process coverage for the playlist's modified-Delete chords. Verifies the
/// dispatch logic and, critically, the disambiguation between plain Delete
/// (remove selected), ⌘⌫ (crop), and ⌘⇧⌫ (clear), plus event consumption and
/// the not-key pass-through. The real-pipeline delivery is covered separately
/// by the UI test.
@MainActor
@Suite("Playlist delete chords")
struct PlaylistDeleteChordTests {
    private let deleteKeyCode: UInt16 = 51

    private func keyEvent(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode
        )!
    }

    @Test("Cmd+Delete crops to the selection and consumes the event")
    func cmdDelete_crops() {
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [1, 3]
        var cropped: Set<Int>?
        var cleared = false
        let result = ui.handleKeyPress(
            event: keyEvent(keyCode: deleteKeyCode, flags: .command),
            isPlaylistKey: true, playlistCount: 5, visibleTrackCount: 5,
            removeTrack: { _ in }, playTrackAt: { _ in },
            cropToSelection: { cropped = $0 }, clearPlaylist: { cleared = true }
        )
        #expect(result == nil)
        #expect(cropped == [1, 3])
        #expect(cleared == false)
        #expect(ui.selectedIndices.isEmpty)
    }

    @Test("Cmd+Shift+Delete clears the list and consumes the event")
    func cmdShiftDelete_clears() {
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [0]
        var cropped = false
        var cleared = false
        let result = ui.handleKeyPress(
            event: keyEvent(keyCode: deleteKeyCode, flags: [.command, .shift]),
            isPlaylistKey: true, playlistCount: 3, visibleTrackCount: 3,
            removeTrack: { _ in }, playTrackAt: { _ in },
            cropToSelection: { _ in cropped = true }, clearPlaylist: { cleared = true }
        )
        #expect(result == nil)
        #expect(cleared == true)
        #expect(cropped == false)
    }

    @Test("Plain Delete removes selected, not crop or clear")
    func plainDelete_removesSelected() {
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [2]
        var removed: [Int] = []
        var cropped = false
        var cleared = false
        let result = ui.handleKeyPress(
            event: keyEvent(keyCode: deleteKeyCode, flags: []),
            isPlaylistKey: true, playlistCount: 3, visibleTrackCount: 3,
            removeTrack: { removed.append($0) }, playTrackAt: { _ in },
            cropToSelection: { _ in cropped = true }, clearPlaylist: { cleared = true }
        )
        #expect(result == nil)
        #expect(removed == [2])
        #expect(cropped == false)
        #expect(cleared == false)
    }

    @Test("Delete chords pass through when the playlist is not key")
    func notPlaylistKey_passesThrough() {
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [0]
        let event = keyEvent(keyCode: deleteKeyCode, flags: [.command, .shift])
        var cleared = false
        let result = ui.handleKeyPress(
            event: event,
            isPlaylistKey: false, playlistCount: 3, visibleTrackCount: 3,
            removeTrack: { _ in }, playTrackAt: { _ in },
            cropToSelection: { _ in }, clearPlaylist: { cleared = true }
        )
        #expect(result === event)
        #expect(cleared == false)
    }
}
