import AppKit
import Foundation
import Testing
@testable import MacAmp

@MainActor
@Suite("Playlist file removal")
struct PlaylistFileRemovalTests {
    private func track(_ url: URL, cue: Bool = false) -> Track {
        Track(
            url: url, title: url.lastPathComponent, artist: "", duration: 10,
            cueSlice: cue ? CueSlice(
                startTime: 0, duration: 10,
                cueSheetURL: url.appendingPathExtension("cue"), trackNumber: 1
            ) : nil
        )
    }

    private func fixtureDirectory() throws -> URL {
        let support = try #require(UnitTestSupport.applicationSupportDirectory)
        let url = support.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Missing-file removal scans all local rows and preserves files, remote URLs and surviving selection")
    func removeMissingFiles() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("existing.wav")
        try Data("audio".utf8).write(to: existing)
        let tracks = [
            track(root.appendingPathComponent("missing.wav")), track(existing),
            track(try #require(URL(string: "https://example.com/radio"))),
            track(try #require(URL(string: "ftp://example.com/audio"))),
            track(root.appendingPathComponent("missing-cue.wav"), cue: true)
        ]
        let player = AudioPlayer()
        tracks.forEach(player.playlistController.addTrack)
        player.updatePlaylistPosition(with: tracks[1])
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [1, 4]
        ui.cursorIndex = 1
        ui.anchorIndex = 4
        let actions = PlaylistWindowActions()

        await actions.removeMissingFiles(audioPlayer: player, interactionState: ui)

        #expect(player.playlist.map(\.id) == Array(tracks[1...3]).map(\.id))
        #expect(ui.selectedIndices == [0])
        #expect(ui.cursorIndex == 0)
        #expect(ui.anchorIndex == nil)
        #expect(actions.selectedIndices == ui.selectedIndices)
        #expect(player.playlistController.currentTrack?.id == tracks[1].id)
        #expect(try Data(contentsOf: existing) == Data("audio".utf8))
    }

    @Test("Unreadable locals are removed while remote URLs are never probed")
    func unreadableLocal() async throws {
        let local = track(URL(fileURLWithPath: "/unreadable.wav"))
        let remote = track(try #require(URL(string: "https://example.com/radio")))
        let outcome = await PlaylistFileRemoval.missingFiles(in: [local, remote]) { url in
            #expect(url.isFileURL)
            return false
        }
        #expect(outcome.removedIDs == [local.id])
    }

    @Test("Physical removal trashes selected files once and combines failures while retaining failed selections")
    func partialTrashWithCueSiblings() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared.wav")
        let denied = root.appendingPathComponent("denied.wav")
        let deniedAgain = root.appendingPathComponent("denied-again.wav")
        for url in [shared, denied, deniedAgain] { try Data().write(to: url) }
        let tracks = [
            track(shared, cue: true), track(shared, cue: true), track(shared, cue: true),
            track(denied), track(deniedAgain),
            track(try #require(URL(string: "https://example.com/radio")))
        ]
        let player = AudioPlayer()
        tracks.forEach(player.playlistController.addTrack)
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [0, 1, 3, 4, 5]
        ui.cursorIndex = 3
        ui.anchorIndex = 1
        var reports: [[PlaylistFileRemoval.Failure]] = []
        var confirmedIDs: Set<UUID> = []

        await PlaylistWindowActions().physicallyRemoveSelectedFiles(
            audioPlayer: player, interactionState: ui,
            confirm: { selected in
                confirmedIDs = Set(selected.map(\.id))
                return true
            },
            trash: { url in
                if url == denied || url == deniedAgain { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("trashed"))
            },
            reportFailures: { reports.append($0) }
        )

        #expect(confirmedIDs == Set([0, 1, 3, 4].map { tracks[$0].id }))
        #expect(player.playlist.map(\.id) == Array(tracks[2...5]).map(\.id))
        #expect(ui.selectedIndices == [1, 2, 3])
        #expect(ui.cursorIndex == 1)
        #expect(ui.anchorIndex == nil)
        #expect(reports.count == 1)
        #expect(Set(try #require(reports.first).map(\.url)) == [denied, deniedAgain])
        #expect(!FileManager.default.fileExists(atPath: shared.path))
        #expect(FileManager.default.fileExists(atPath: shared.appendingPathExtension("trashed").path))
        #expect(FileManager.default.fileExists(atPath: denied.path))
    }

    @Test("Cancellation preserves rows, selection and files without attempting trash")
    func cancelTrash() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("keep.wav")
        try Data().write(to: file)
        let player = AudioPlayer()
        let selected = track(file)
        player.playlistController.addTrack(selected)
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [0]
        ui.cursorIndex = 0
        ui.anchorIndex = 0
        await PlaylistWindowActions().physicallyRemoveSelectedFiles(
            audioPlayer: player, interactionState: ui,
            confirm: { _ in false },
            trash: { _ in Issue.record("Cancellation attempted filesystem removal") },
            reportFailures: { _ in Issue.record("Cancellation reported a failure") }
        )
        #expect(player.playlist == [selected])
        #expect(ui.selectedIndices == [0])
        #expect(ui.cursorIndex == 0)
        #expect(ui.anchorIndex == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Empty, invalid and remote-only selections skip confirmation")
    func noLocalSelection() async throws {
        let player = AudioPlayer()
        let remote = track(try #require(URL(string: "https://example.com/radio")))
        player.playlistController.addTrack(remote)
        for selection: Set<Int> in [[], [-1, 99], [0]] {
            let ui = PlaylistWindowInteractionState()
            ui.selectedIndices = selection
            await PlaylistWindowActions().physicallyRemoveSelectedFiles(
                audioPlayer: player, interactionState: ui,
                confirm: { _ in Issue.record("No local selection requested confirmation"); return true },
                trash: { _ in Issue.record("No local selection attempted trash") }
            )
            #expect(ui.selectedIndices == selection)
            #expect(player.playlist == [remote])
        }
    }

    @Test("A delayed result removes only snapshot identities after playlist replacement and reordering")
    func staleSnapshot() async {
        let url = URL(fileURLWithPath: "/missing.wav")
        let removed = track(url)
        let survivor = track(URL(fileURLWithPath: "/survivor.wav"))
        let obsolete = track(url)
        let player = AudioPlayer()
        [removed, survivor, obsolete].forEach(player.playlistController.addTrack)
        let result = PlaylistFileRemoval.Outcome(removedIDs: [removed.id, obsolete.id])
        player.removeTrack(at: 2)
        let replacement = track(url)
        player.playlistController.addTrack(replacement)
        player.moveTracks(at: [0], by: 1)
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [0, 2]
        ui.cursorIndex = 2
        ui.anchorIndex = 0
        PlaylistWindowActions().applyRemoval(result, audioPlayer: player, interactionState: ui)
        #expect(player.playlist == [survivor, replacement])
        #expect(ui.selectedIndices == [0, 1])
        #expect(ui.cursorIndex == 1)
        #expect(ui.anchorIndex == 0)
    }

    @Test("The submenu dispatches missing-file removal without opening windows")
    func submenuDispatch() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let player = AudioPlayer()
        player.playlistController.addTrack(track(root.appendingPathComponent("missing.wav")))
        let ui = PlaylistWindowInteractionState()
        let menu = PlaylistMenuPresenter.makeRemoveMiscMenu(audioPlayer: player, interactionState: ui)
        let item = try #require(menu.items.first)
        #expect(menu.items.map(\.title) == [
            "Remove missing files from playlist", "Physically remove selected file(s)"
        ])
        #expect(item.keyEquivalent.isEmpty)
        let target = try #require(item.target as? MenuActionTarget)
        target.execute()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !player.playlist.isEmpty && clock.now < deadline { await Task.yield() }
        #expect(player.playlist.isEmpty)
    }

    @Test("Remove Selected removes playlist rows while leaving the file on disk")
    func playlistOnlyRemoval() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("keep.wav")
        let data = Data("keep this file".utf8)
        try data.write(to: file)
        let player = AudioPlayer()
        player.playlistController.addTrack(track(file))
        let actions = PlaylistWindowActions.shared
        let savedSelection = actions.selectedIndices
        defer { actions.selectedIndices = savedSelection }
        actions.selectedIndices = [0]
        let sender = NSMenuItem()
        sender.representedObject = player
        actions.removeSelected(sender)
        #expect(player.playlist.isEmpty)
        #expect(try Data(contentsOf: file) == data)
    }

    @Test("Production trash is disabled in unit tests")
    func unitTestTrashIsolation() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("protected.wav")
        try Data().write(to: file)
        #expect(throws: CocoaError.self) { try PlaylistFileRemoval.trashFile(file) }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
