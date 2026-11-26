import AppKit
import Foundation
import Testing
@testable import MacAmp

@MainActor
@Suite("Playlist Entry policy")
struct PlaylistEntryPolicyTests {
    private func cueTrack() -> Track {
        Track(url: URL(fileURLWithPath: "/music/album.wav"), title: "Segment", artist: "Artist", duration: 12,
              cueSlice: CueSlice(startTime: 30, duration: 12,
                                 cueSheetURL: URL(fileURLWithPath: "/music/album.cue"), trackNumber: 3))
    }

    @Test("A rejected CUE transition preserves an in-flight refresh and pending reservations")
    func rejectionKeepsRefresh() async throws {
        let player = AudioPlayer()
        let original = cueTrack()
        player.playlistController.addTrack(original)
        let replacement = URL(fileURLWithPath: "/music/replacement.wav")
        let (stream, continuation) = AsyncStream<MetadataLoader.TrackMetadata>.makeStream()
        let refresh = try #require(player.editPlaylistEntry(id: original.id, expectedURL: original.url,
                                                           url: replacement, loadMetadata: { _ in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next() ?? .init(title: "", artist: "", duration: 0)
        }))
        let snapshot = player.playlist[0]
        player.playlistController.addPendingURL(replacement)
        var forbiddenLoads = 0
        let rejected = player.editPlaylistEntry(
            id: original.id, expectedURL: replacement, url: try #require(URL(string: "https://example.com/live")),
            loadMetadata: { _ in forbiddenLoads += 1; return .init(title: "Wrong", artist: "", duration: 0) }
        )
        #expect(rejected == nil)
        #expect(forbiddenLoads == 0)
        #expect(player.playlist[0].id == snapshot.id)
        #expect(player.playlist[0].url == snapshot.url)
        #expect(player.playlist[0].title == snapshot.title)
        #expect(player.playlist[0].artist == snapshot.artist)
        #expect(player.playlist[0].duration == snapshot.duration)
        #expect(player.playlist[0].cueSlice == snapshot.cueSlice)
        continuation.yield(.init(title: "Refreshed", artist: "Refreshed artist", duration: 200))
        continuation.finish()
        await refresh.value
        #expect(player.playlist[0].title == "Refreshed")
        #expect(player.playlist[0].duration == 12)
        #expect(player.playlist[0].cueSlice == snapshot.cueSlice)
        player.playlistController.removeTrack(at: 0)
        #expect(player.playlistController.containsTrack(url: replacement))
        player.playlistController.removePendingURL(replacement)
    }

    @Test("CUE validation repeats the same editor for correction or cancellation", arguments: [false, true])
    func retryCueTransition(cancel: Bool) async {
        let player = AudioPlayer()
        let original = cueTrack()
        let other = Track(url: URL(fileURLWithPath: "/music/other.wav"), title: "Other", artist: "", duration: 10)
        [original, other].forEach(player.playlistController.addTrack)
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [0, 1]
        ui.cursorIndex = 0
        ui.anchorIndex = 1
        var prompts: [UUID] = []
        var errors: [String?] = []
        var loads = 0
        let refreshes = PlaylistWindowActions().editPlaylistEntries(
            audioPlayer: player, interactionState: ui,
            prompt: { track, error in
                prompts.append(track.id)
                errors.append(error)
                if prompts.count == 1 { return "https://example.com/live" }
                if prompts.count == 2 { return cancel ? nil : "/music/corrected.wav" }
                return nil
            },
            loadMetadata: { _ in loads += 1; return .init(title: "Corrected", artist: "", duration: 90) }
        )
        for refresh in refreshes { await refresh.value }
        #expect(prompts.prefix(2) == [original.id, original.id])
        #expect(errors[0] == nil)
        #expect(errors[1]?.contains("CUE segment") == true)
        #expect(loads == (cancel ? 0 : 1))
        #expect(player.playlist[0].url.path == (cancel ? original.url.path : "/music/corrected.wav"))
        #expect(player.playlist[0].cueSlice == original.cueSlice)
        #expect(player.playlist[0].duration == original.duration)
        #expect(player.playlist[1].url == other.url)
        #expect(ui.selectedIndices == [0, 1])
        #expect(ui.cursorIndex == 0)
        #expect(ui.anchorIndex == 1)
        if cancel {
            #expect(prompts.count == 2)
            #expect(player.playlist[0].title == original.title)
            #expect(player.playlist[0].artist == original.artist)
        }
    }

    @Test("Remote entries retain remote editing even when stored slice bounds are present", arguments: [false, true])
    func ordinaryRemoteEntries(hasSlice: Bool) throws {
        let player = AudioPlayer()
        var original = cueTrack()
        original.url = try #require(URL(string: "https://example.com/old"))
        if !hasSlice { original.cueSlice = nil }
        player.addStreamTrack(original)
        let url = try #require(URL(string: "http://example.com/new?q=1#station"))
        player.editPlaylistEntry(id: original.id, expectedURL: original.url, url: url,
                                 loadMetadata: { _ in Issue.record("A remote edit loaded local metadata"); return .init(title: "", artist: "", duration: 0) })
        #expect(player.playlist[0].url == url)
        #expect(player.playlist[0].id == original.id)
        #expect(player.playlist[0].cueSlice == original.cueSlice)
        #expect(player.playlist[0].duration == original.duration)
    }

    @Test("Editors advance before metadata completes and a reentrant sequence is ignored")
    func nonblockingSequence() async {
        let player = AudioPlayer()
        let tracks = ["A", "B"].map {
            Track(url: URL(fileURLWithPath: "/music/\($0).wav"), title: $0, artist: "", duration: 10)
        }
        tracks.forEach(player.playlistController.addTrack)
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [0, 1]
        let actions = PlaylistWindowActions()
        let (stream, continuation) = AsyncStream<MetadataLoader.TrackMetadata>.makeStream()
        var prompted: [UUID] = []
        var nestedPrompts = 0
        let refreshes = actions.editPlaylistEntries(audioPlayer: player, interactionState: ui, prompt: { track, _ in
            prompted.append(track.id)
            if prompted.count == 1 {
                actions.editPlaylistEntries(audioPlayer: player, interactionState: ui, prompt: { _, _ in
                    nestedPrompts += 1
                    return nil
                })
                return "/music/replacement.wav"
            }
            #expect(player.playlist[0].url.path == "/music/replacement.wav")
            #expect(player.playlist[0].title == "replacement.wav")
            return nil
        }, loadMetadata: { _ in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next() ?? .init(title: "", artist: "", duration: 0)
        })
        #expect(prompted == tracks.map(\.id))
        #expect(nestedPrompts == 0)
        #expect(refreshes.count == 1)
        continuation.yield(.init(title: "Refreshed", artist: "", duration: 100))
        continuation.finish()
        for refresh in refreshes { await refresh.value }
        #expect(player.playlist[0].title == "Refreshed")
        var laterPrompts = 0
        actions.editPlaylistEntries(audioPlayer: player, interactionState: ui, prompt: { _, _ in
            laterPrompts += 1
            return nil
        })
        #expect(laterPrompts == 1)
    }

    @Test("Native entry fields use intrinsic layout and scroll long or short locations",
          arguments: ["/a.wav", "/music/" + String(repeating: "long-location-", count: 40) + ".wav"])
    func editorFields(_ location: String) {
        let fields = PlaylistEntryEditorFields(old: location, new: location)
        #expect(fields.oldValue.stringValue == location)
        #expect(fields.newValue.stringValue == location)
        #expect(!fields.oldValue.isEditable)
        #expect(fields.oldValue.isSelectable)
        #expect(fields.newValue.isEditable)
        #expect(fields.oldValue.usesSingleLineMode)
        #expect(fields.newValue.usesSingleLineMode)
        #expect(fields.oldValue.cell?.isScrollable == true)
        #expect(fields.newValue.cell?.isScrollable == true)
        #expect(fields.grid.fittingSize.width > 0)
        #expect(fields.grid.fittingSize.height > 0)
        #expect(fields.grid.window == nil)
    }

    @Test("The native prompt returns before creating a window in unit tests")
    func promptGuard() {
        #expect(UnitTestSupport.isActive)
        #expect(PlaylistEntryEditor().prompt(cueTrack(), error: nil) == nil)
    }
}
