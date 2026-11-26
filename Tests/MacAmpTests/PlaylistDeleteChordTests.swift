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

@MainActor
@Suite("Playlist selection menu")
struct PlaylistSelectionMenuTests {
    private func tracks(_ count: Int) -> [Track] {
        (0..<count).map {
            Track(url: URL(fileURLWithPath: "/selection-\($0).wav"), title: "Track \($0)", artist: "", duration: 10)
        }
    }

    @Test("Selection tiles use current rows and preserve playback and navigation", arguments: 0..<3)
    func liveSelection(command: Int) {
        let player = AudioPlayer()
        defer { player.stop() }
        let rows = tracks(4)
        rows.prefix(2).forEach(player.playlistController.addTrack)
        let ui = PlaylistWindowInteractionState()
        let actions = PlaylistWindowActions()
        let tiles = PlaylistMenuPresenter.makeSelectionTiles(audioPlayer: player, interactionState: ui, actions: actions)
        rows.suffix(2).forEach(player.playlistController.addTrack)
        ui.selectedIndices = [-1, 1, 3, 99]
        ui.cursorIndex = 2
        ui.anchorIndex = 1
        ui.scrollOffsetPixels = 13
        player.currentTrack = rows[2]
        player.updatePlaylistPosition(with: rows[2])
        player.currentTime = 3
        player.playbackProgress = 0.3
        let playbackState = player.playbackState
        actions.selectedIndices = [0]
        tiles[command].action()
        let expected: Set<Int> = command == 0 ? [0, 2] : command == 1 ? [] : [0, 1, 2, 3]
        #expect(ui.selectedIndices == expected)
        #expect(actions.selectedIndices == expected)
        #expect(ui.cursorIndex == 2)
        #expect(ui.anchorIndex == 1)
        #expect(ui.scrollOffsetPixels == 13)
        #expect(player.playlist == rows)
        #expect(player.currentTrack == rows[2])
        #expect(player.playlistController.currentTrack == rows[2])
        #expect(player.currentTime == 3)
        #expect(player.playbackProgress == 0.3)
        #expect(player.playbackState == playbackState)
        if command == 0 {
            tiles[command].action()
            #expect(ui.selectedIndices == [1, 3])
            #expect(actions.selectedIndices == [1, 3])
        }
    }

    @Test("Selection commands on an empty playlist leave no selected rows", arguments: 0..<3)
    func emptyPlaylist(command: Int) {
        let player = AudioPlayer()
        defer { player.stop() }
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [99]
        let actions = PlaylistWindowActions()
        let tiles = PlaylistMenuPresenter.makeSelectionTiles(audioPlayer: player, interactionState: ui, actions: actions)
        tiles[command].action()
        #expect(ui.selectedIndices.isEmpty)
        #expect(actions.selectedIndices.isEmpty)
        #expect(ui.cursorIndex == nil)
        #expect(ui.anchorIndex == nil)
        #expect(ui.scrollOffsetPixels == 0)
        #expect(player.playlist.isEmpty)
    }

    @Test("Shift navigation extends from the anchor preserved by selection commands", arguments: 0..<3)
    func rangeAnchor(command: Int) throws {
        let player = AudioPlayer()
        defer { player.stop() }
        tracks(5).forEach(player.playlistController.addTrack)
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [1, 2]
        ui.cursorIndex = 2
        ui.anchorIndex = 1
        PlaylistMenuPresenter.makeSelectionTiles(audioPlayer: player, interactionState: ui,
                                                actions: PlaylistWindowActions())[command].action()
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125
        ))
        #expect(ui.handleKeyPress(event: event, isPlaylistKey: true, playlistCount: 5, visibleTrackCount: 5,
                                  removeTrack: { _ in }, playTrackAt: { _ in }) == nil)
        #expect(ui.selectedIndices == [1, 2, 3])
        #expect(ui.cursorIndex == 3)
        #expect(ui.anchorIndex == 1)
    }

    @Test("SEL followed by removal or crop clears displayed selection and follows surviving rows",
          arguments: 0..<3, [2, 3])
    func subsequentActions(selectionCommand: Int, removalCommand: Int) {
        let player = AudioPlayer()
        defer { player.stop() }
        let rows = tracks(5)
        rows.forEach(player.playlistController.addTrack)
        let ui = PlaylistWindowInteractionState()
        let actions = PlaylistWindowActions()
        let selections = PlaylistMenuPresenter.makeSelectionTiles(audioPlayer: player, interactionState: ui, actions: actions)
        let removals = PlaylistMenuPresenter.makeRemoveTiles(audioPlayer: player, interactionState: ui,
                                                            actions: actions, removeMisc: {})
        ui.selectedIndices = [0, 2, 4]
        ui.cursorIndex = 3
        ui.anchorIndex = 2
        selections[selectionCommand].action()
        let selected = ui.selectedIndices
        actions.selectedIndices = [99]
        removals[removalCommand].action()
        let expectedRows = selected.isEmpty ? rows : rows.enumerated().filter {
            removalCommand == 2 ? selected.contains($0.offset) : !selected.contains($0.offset)
        }.map(\.element)
        #expect(player.playlist == expectedRows)
        #expect(ui.selectedIndices.isEmpty)
        #expect(actions.selectedIndices.isEmpty)
        #expect(ui.cursorIndex == expectedRows.firstIndex(of: rows[3]))
        #expect(ui.anchorIndex == expectedRows.firstIndex(of: rows[2]))
        removals[removalCommand].action()
        #expect(player.playlist == expectedRows)
        selections[0].action()
        #expect(ui.selectedIndices == Set(expectedRows.indices))
        #expect(actions.selectedIndices == ui.selectedIndices)
        removals[3].action()
        #expect(player.playlist.isEmpty)
        #expect(ui.selectedIndices.isEmpty)
        #expect(actions.selectedIndices.isEmpty)
    }

    @Test("Removal and crop cancel dragging and ignore stale row indices", arguments: [2, 3])
    func staleRows(removalCommand: Int) {
        let player = AudioPlayer()
        defer { player.stop() }
        let rows = tracks(4)
        rows.forEach(player.playlistController.addTrack)
        let ui = PlaylistWindowInteractionState()
        ui.pressRow(index: 1, yFromTop: 2, windowY: 500)
        ui.selectedIndices = [-1, 1, 99]
        ui.cursorIndex = 3
        ui.anchorIndex = 1
        let actions = PlaylistWindowActions()
        let removals = PlaylistMenuPresenter.makeRemoveTiles(audioPlayer: player, interactionState: ui,
                                                            actions: actions, removeMisc: {})
        removals[removalCommand].action()
        #expect(player.playlist == (removalCommand == 2 ? [rows[1]] : [rows[0], rows[2], rows[3]]))
        #expect(ui.cursorIndex == (removalCommand == 2 ? nil : 2))
        #expect(ui.anchorIndex == (removalCommand == 2 ? 0 : nil))
        ui.dragRows(windowY: 400, viewportHeight: 200, maxScroll: 100) { _, _ in
            Issue.record("Removal left a row drag active")
            return false
        }
        ui.releaseRow(windowY: 500)
        #expect(ui.selectedIndices.isEmpty)
        #expect(actions.selectedIndices.isEmpty)
    }
}
