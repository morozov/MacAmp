import AppKit
import Foundation
import Testing
@testable import MacAmp

@MainActor
@Suite("Playlist Misc Options")
struct PlaylistMiscOptionsTests {
    @Test("Misc Options dispatches export and reads selection when rebuilding is chosen")
    func menuDispatch() async throws {
        let player = AudioPlayer()
        let tracks = ["A", "B"].map {
            Track(url: URL(fileURLWithPath: "/music/\($0).wav"), title: $0, artist: "", duration: 42)
        }
        tracks.forEach(player.playlistController.addTrack)
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [0]
        let actions = PlaylistWindowActions()
        actions.selectedIndices = [0]
        var exports = 0
        var task: Task<Void, Never>?
        var loads: [URL] = []
        let menu = PlaylistMenuPresenter.makeMiscOptionsMenu(generateHTML: { exports += 1 }, rebuildTitles: {
            task = actions.rebuildTitles(audioPlayer: player, interactionState: ui, loadMetadata: { url in
                loads.append(url)
                return .init(title: "Fresh", artist: "New artist", duration: 99)
            })
        })
        #expect(menu.items.map(\.title) == ["Generate HTML playlist", "", "Rebuild titles on selection"])
        #expect(menu.items[1].isSeparatorItem)
        #expect(menu.items.allSatisfy { $0.keyEquivalent.isEmpty })
        ui.selectedIndices = [1, -1, 99]
        ui.cursorIndex = 1
        ui.anchorIndex = 1
        try #require(menu.items[0].target as? MenuActionTarget).execute()
        try #require(menu.items[2].target as? MenuActionTarget).execute()
        await task?.value
        #expect(exports == 1)
        #expect(loads == [tracks[1].url])
        #expect(player.playlist.map(\.title) == ["A", "Fresh"])
        #expect(ui.selectedIndices == [1, -1, 99])
        #expect(ui.cursorIndex == 1)
        #expect(ui.anchorIndex == 1)
        ui.selectedIndices = []
        await actions.rebuildTitles(audioPlayer: player, interactionState: ui, loadMetadata: { _ in
            Issue.record("An empty selection must not load metadata")
            return .init(title: "Wrong", artist: "", duration: 0)
        }).value
        #expect(player.playlist.map(\.title) == ["A", "Fresh"])
    }

    @Test("Received ICY metadata rebuilds matching URLs without reusing seeded station labels")
    func streamProvenance() async throws {
        let url = try #require(URL(string: "https://example.com/live.m3u8"))
        let otherURL = try #require(URL(string: "https://example.com/other.m3u8"))
        let tracks = [Track(url: url, title: "Seeded station", artist: "Seeded artist", duration: 0),
                      Track(url: url, title: "Other label", artist: "", duration: 0),
                      Track(url: otherURL, title: "Other station", artist: "", duration: 0)]
        let player = AudioPlayer()
        tracks.forEach(player.playlistController.addTrack)
        let stream = StreamPlayer()
        stream.pipelineForTesting.playlistFetch = { _ in throw CancellationError() }
        stream.pipelineForTesting.hlsFetch = { _ in throw CancellationError() }
        let coordinator = PlaybackCoordinator(audioPlayer: player, streamPlayer: stream)
        defer { coordinator.stop() }
        let actions = PlaylistWindowActions()
        actions.playbackCoordinator = coordinator
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [0, 1, 2]
        let loader: (URL) async -> MetadataLoader.TrackMetadata = { _ in
            Issue.record("Stream rebuilding must not load file metadata")
            return .init(title: "Wrong", artist: "", duration: 99)
        }
        await coordinator.play(track: tracks[0])
        #expect(stream.streamTitle == "Seeded station")
        #expect(stream.receivedTitleMetadata == nil)
        #expect(coordinator.playlistStreamTitle == nil)
        await actions.rebuildTitles(audioPlayer: player, interactionState: ui, loadMetadata: loader).value
        #expect(player.playlist.map(\.title) == [url.absoluteString, url.absoluteString, otherURL.absoluteString])
        stream.pipelineForTesting.onMetadata?(.init(title: "Song", artist: "Artist"))
        await actions.rebuildTitles(audioPlayer: player, interactionState: ui, loadMetadata: loader).value
        #expect(player.playlist.map(\.title) == ["Artist - Song", "Artist - Song", otherURL.absoluteString])
        stream.pipelineForTesting.onMetadata?(.init(title: "Next song", artist: nil))
        #expect(stream.streamArtist == "Artist")
        #expect(stream.receivedTitleMetadata?.artist == nil)
        await actions.rebuildTitles(audioPlayer: player, interactionState: ui, loadMetadata: loader).value
        #expect(player.playlist.map(\.title) == ["Next song", "Next song", otherURL.absoluteString])
        await coordinator.play(track: tracks[2])
        #expect(stream.receivedTitleMetadata == nil)
        #expect(coordinator.playlistStreamTitle == nil)
        stream.pipelineForTesting.onMetadata?(.init(title: "New source", artist: nil))
        #expect(coordinator.playlistStreamTitle?.url == otherURL)
        coordinator.stop()
        #expect(stream.receivedTitleMetadata == nil)
        #expect(coordinator.playlistStreamTitle == nil)
        #expect(player.playlist.map(\.id) == tracks.map(\.id))
    }
}
