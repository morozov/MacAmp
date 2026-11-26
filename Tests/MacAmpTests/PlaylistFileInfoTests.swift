import AppKit
import Foundation
import Testing
@testable import MacAmp

@MainActor
@Suite("Playlist File Info")
struct PlaylistFileInfoTests {
    private func track(_ name: String) -> Track {
        Track(url: URL(fileURLWithPath: "/music/\(name).wav"), title: name, artist: "Artist", duration: 42)
    }

    private func player(_ tracks: [Track]) -> AudioPlayer {
        let player = AudioPlayer()
        tracks.forEach(player.playlistController.addTrack)
        return player
    }

    private func shown(_ advance: PlaylistFileInfoSession.Advance) -> Track? {
        if case .show(let track) = advance { return track }
        return nil
    }

    @Test("File Info uses the live selection in row order without a playing-track fallback")
    func selection() {
        let tracks = [track("A"), track("B"), track("C")]
        let player = player(tracks)
        player.currentTrack = tracks[0]
        let ui = PlaylistWindowInteractionState()
        let actions = PlaylistWindowActions()
        actions.selectedIndices = [0]
        var shown: [[UUID]] = []
        actions.presentFileInfo = { shown.append($0.map(\.id)) }
        ui.selectedIndices = [2, 1, -1, 90]
        actions.fileInfo(audioPlayer: player, interactionState: ui)
        ui.selectedIndices = []
        actions.fileInfo(audioPlayer: player, interactionState: ui)
        #expect(shown == [[tracks[1].id, tracks[2].id]])
    }

    @Test("Done advances selected identities after reorder and skips removed rows")
    func sessionContinuation() {
        let tracks = [track("A"), track("B"), track("C")]
        var session = PlaylistFileInfoSession()
        session.start(tracks)
        #expect(shown(session.advance(in: tracks))?.id == tracks[0].id)
        #expect(shown(session.advance(in: [tracks[2], tracks[0]]))?.id == tracks[2].id)
        guard case .close = session.advance(in: tracks) else {
            Issue.record("Done at the end must close the panel")
            return
        }
    }

    @Test("The File Info submenu dispatches both commands and reads selection when invoked")
    func menuDispatch() throws {
        let tracks = [track("A"), track("B")]
        let player = player(tracks)
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [0]
        let actions = PlaylistWindowActions()
        var shown: [UUID] = []
        var entryRequests = 0
        actions.presentFileInfo = { shown = $0.map(\.id) }
        let menu = PlaylistMenuPresenter.makeFileInfoMenu(
            audioPlayer: player, interactionState: ui, actions: actions,
            editEntries: { entryRequests += 1 }
        )
        #expect(menu.items.map(\.title) == ["File info...", "Playlist entry..."])
        ui.selectedIndices = [1]
        try #require(menu.items[0].target as? MenuActionTarget).execute()
        try #require(menu.items[1].target as? MenuActionTarget).execute()
        #expect(shown == [tracks[1].id])
        #expect(entryRequests == 1)
        #expect(menu.items.allSatisfy { $0.keyEquivalent.isEmpty })
    }

    @Test("Closing, navigation and new selections invalidate pending File Info requests")
    func sessionSupersession() {
        let tracks = [track("A"), track("B")]
        var session = PlaylistFileInfoSession()
        session.start(tracks)
        let first = session.beginRequest()
        session.cancel()
        #expect(session.request != first)
        #expect(!session.isSelecting)
        #expect(shown(session.advance(in: tracks)) == nil)
        session.start([tracks[1]])
        let second = session.beginRequest()
        session.start([tracks[0]])
        #expect(session.request != second)
        #expect(shown(session.advance(in: tracks))?.id == tracks[0].id)
    }

    @Test("Done waits for presentation and completion resolves removed or changed targets")
    func sessionLoading() {
        let tracks = [track("A"), track("B")]
        var session = PlaylistFileInfoSession()
        session.start(tracks)
        #expect(shown(session.advance(in: tracks))?.id == tracks[0].id)
        let request = session.beginRequest()
        #expect(!session.canFinish)
        for _ in 0..<2 {
            guard case .waiting = session.advance(in: tracks) else {
                Issue.record("Done skipped a row while its information was loading")
                return
            }
        }
        var updated = tracks[0]
        updated.title = "Latest title"
        guard case .present(let presented) = session.completeRequest(request, track: tracks[0], in: [updated, tracks[1]]) else {
            Issue.record("The current request did not present its target")
            return
        }
        #expect(presented?.title == "Latest title")
        #expect(!session.isLoading)
        #expect(session.canFinish)
        #expect(shown(session.advance(in: tracks))?.id == tracks[1].id)
        let second = session.beginRequest()
        var relocated = tracks[1]
        relocated.url = URL(fileURLWithPath: "/music/relocated.wav")
        guard case .reload(let reload) = session.completeRequest(second, track: tracks[1], in: [relocated]) else {
            Issue.record("A changed URL must reload its file information")
            return
        }
        #expect(reload.url == relocated.url)
        let third = session.beginRequest()
        guard case .skip = session.completeRequest(third, track: relocated, in: []) else {
            Issue.record("A removed selection must be skipped")
            return
        }
        guard case .close = session.advance(in: []) else {
            Issue.record("An exhausted selection must close")
            return
        }
    }

    @Test("A newer request and closing reject older completions; navigation ends selection")
    func sessionCompletionLifetime() {
        let tracks = [track("A"), track("B")]
        var session = PlaylistFileInfoSession()
        session.start(tracks)
        let first = session.beginRequest()
        let second = session.beginRequest()
        guard case .superseded = session.completeRequest(first, track: tracks[0], in: tracks) else {
            Issue.record("The old request changed the active presentation")
            return
        }
        #expect(session.isLoading)
        session.cancel()
        guard case .superseded = session.completeRequest(second, track: tracks[0], in: tracks) else {
            Issue.record("Closing must reject a pending load")
            return
        }
        #expect(!session.isSelecting)
        let navigation = session.beginRequest()
        #expect(session.canFinish)
        guard case .present(let selected) = session.completeRequest(navigation, track: tracks[1], in: []) else {
            Issue.record("Ordinary navigation must present without a selection queue")
            return
        }
        #expect(selected?.id == tracks[1].id)
        guard case .close = session.advance(in: tracks) else {
            Issue.record("Done after navigation must close the panel")
            return
        }
    }

    @Test("Stream information uses the complete selected URL and matches playback by identity")
    func streams() throws {
        let url = try #require(URL(string: "https://radio.example/live?q=one#station"))
        let active = Track(url: url, title: "Active", artist: "", duration: 0)
        let other = Track(url: url, title: "Other entry", artist: "", duration: 0)
        let source = PlaybackCoordinator.PlaybackSource.radioStation(RadioStation(name: "Radio", streamURL: url))
        #expect(TrackInfoView.location(of: other) == url.absoluteString)
        #expect(TrackInfoView.isActiveStream(target: active, currentTrack: active, source: source))
        #expect(!TrackInfoView.isActiveStream(target: other, currentTrack: active, source: source))
        #expect(!TrackInfoView.isActiveStream(target: other, currentTrack: active, source: .localTrack(url)))
        #expect(TrackInfoView.isActiveStream(target: nil, currentTrack: nil, source: source))
    }

    @Test("Entry locations accept absolute paths, tilde paths and complete supported URLs",
          arguments: ["/missing/file name.wav", "~/Music/file.wav", "file:///music/file%20name.wav",
                      "https://example.com/live?q=one%20two#station", "http://example.com/live", " /music/a.wav \n"])
    func acceptedLocation(_ text: String) {
        #expect(PlaylistEntryLocation.url(from: text) != nil)
    }

    @Test("Entry locations reject empty input, relative paths, bare hosts and unsupported schemes",
          arguments: ["", " \n\t", "~", "song.wav", "music/song.wav", "example.com/live",
                      "ftp://example.com/song", "https://", "file:song.wav"])
    func rejectedLocation(_ text: String) {
        #expect(PlaylistEntryLocation.url(from: text) == nil)
    }

    @Test("Location parsing preserves decoded file paths and complete remote URLs")
    func parsedLocations() throws {
        #expect(try #require(PlaylistEntryLocation.url(from: "file:///music/file%20name.wav")).path == "/music/file name.wav")
        #expect(try #require(PlaylistEntryLocation.url(from: "https://example.com/live?q=one%20two#station")).absoluteString
                == "https://example.com/live?q=one%20two#station")
        #expect(try #require(PlaylistEntryLocation.url(from: "~/Music/file.wav")).path
                == ("~/Music/file.wav" as NSString).expandingTildeInPath)
    }

    @Test("Entry editing preserves identity, duration, selection and the loaded playback snapshot")
    func editIdentity() async throws {
        let tracks = [track("A"), track("B")]
        let player = player(tracks)
        player.selectTrackForPlayback(tracks[0])
        player.currentTime = 7
        let state = player.playbackState
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [0]
        ui.cursorIndex = 0
        ui.anchorIndex = 0
        let actions = PlaylistWindowActions()
        let refreshes = actions.editPlaylistEntries(audioPlayer: player, interactionState: ui,
                                         prompt: { _, _ in "/music/replaced.wav" },
                                         loadMetadata: { _ in .init(title: "Replacement", artist: "New artist", duration: 100) })
        for refresh in refreshes { await refresh.value }
        let edited = try #require(player.playlist.first)
        #expect(edited.id == tracks[0].id)
        #expect(edited.url.path == "/music/replaced.wav")
        #expect(edited.title == "Replacement")
        #expect(edited.artist == "New artist")
        #expect(edited.duration == 42)
        #expect(player.playlistPosition == 1)
        #expect(player.currentTrack?.url == tracks[0].url)
        #expect(player.currentTime == 7)
        #expect(player.playbackState == state)
        #expect(ui.selectedIndices == [0])
        #expect(ui.cursorIndex == 0)
        #expect(ui.anchorIndex == 0)
    }

    @Test("An empty selection never prompts and unchanged OK performs no metadata work")
    func emptyAndUnchanged() async {
        let original = track("A")
        let player = player([original])
        let ui = PlaylistWindowInteractionState()
        let actions = PlaylistWindowActions()
        var prompts = 0
        var loads = 0
        let prompt: (Track, String?) -> String? = { track, _ in
            prompts += 1
            return track.url.path
        }
        let loader: (URL) async -> MetadataLoader.TrackMetadata = { _ in
            loads += 1
            return .init(title: "Wrong", artist: "", duration: 0)
        }
        let emptyRefreshes = actions.editPlaylistEntries(audioPlayer: player, interactionState: ui, prompt: prompt, loadMetadata: loader)
        for refresh in emptyRefreshes { await refresh.value }
        #expect(prompts == 0)
        ui.selectedIndices = [0]
        let unchangedRefreshes = actions.editPlaylistEntries(audioPlayer: player, interactionState: ui, prompt: prompt, loadMetadata: loader)
        for refresh in unchangedRefreshes { await refresh.value }
        #expect(prompts == 1)
        #expect(loads == 0)
        #expect(player.playlist[0].title == original.title)
    }

    @Test("Validation repeats the editor and cancellation stops the remaining selection")
    func invalidAndCancel() async {
        let tracks = [track("A"), track("B"), track("C")]
        let player = player(tracks)
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [2, 0, 1]
        let actions = PlaylistWindowActions()
        var prompts: [UUID] = []
        var errors: [String?] = []
        let refreshes = actions.editPlaylistEntries(audioPlayer: player, interactionState: ui, prompt: { track, error in
            prompts.append(track.id)
            errors.append(error)
            switch prompts.count {
            case 1: return "relative.wav"
            case 2: return "https://example.com/replacement?q=1#x"
            default: return nil
            }
        }, loadMetadata: { _ in Issue.record("Remote entries must not load local metadata"); return .init(title: "", artist: "", duration: 0) })
        for refresh in refreshes { await refresh.value }
        #expect(prompts == [tracks[0].id, tracks[0].id, tracks[1].id])
        #expect(errors[0] == nil)
        #expect(errors[1] != nil)
        #expect(player.playlist[0].url.absoluteString == "https://example.com/replacement?q=1#x")
        #expect(player.playlist[0].title == player.playlist[0].url.absoluteString)
        #expect(player.playlist[1].url == tracks[1].url)
        #expect(player.playlist[2].url == tracks[2].url)
    }

    @Test("Editing bypasses deduplication and targets identities after rows move or disappear")
    func movingTargets() async {
        let tracks = [track("A"), track("B"), track("C")]
        let player = player(tracks)
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [0, 1, 2]
        var prompted: [UUID] = []
        let refreshes = PlaylistWindowActions().editPlaylistEntries(audioPlayer: player, interactionState: ui, prompt: { track, _ in
            prompted.append(track.id)
            if prompted.count == 1 {
                player.playlistController.removeTrack(at: 1)
                player.reorderPlaylist(.reverse)
            }
            return "https://example.com/same"
        })
        for refresh in refreshes { await refresh.value }
        #expect(prompted == [tracks[0].id, tracks[2].id])
        #expect(player.playlist.map(\.id) == [tracks[2].id, tracks[0].id])
        #expect(Set(player.playlist.map(\.url)).count == 1)
    }
}
