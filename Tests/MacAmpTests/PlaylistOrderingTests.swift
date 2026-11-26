import AppKit
import AVFoundation
import Foundation
import Testing
@testable import MacAmp

@MainActor
@Suite("Playlist ordering")
struct PlaylistOrderingTests {
    private func track(_ path: String, title: String = "", artist: String = "") -> Track {
        Track(url: URL(fileURLWithPath: path), title: title, artist: artist, duration: 10)
    }

    private func controller(_ tracks: [Track]) -> PlaylistController {
        let controller = PlaylistController()
        tracks.forEach(controller.addTrack)
        return controller
    }

    @Test("Title sorting follows displayed artist and title with natural numeric order")
    func displayedTitle() {
        let tracks = [
            track("/z", title: "Track 10", artist: "Artist"),
            track("/b", title: "Zulu", artist: "Alpha"),
            track("/a", title: "Alpha", artist: "Zulu"),
            track("/c", title: "track 2", artist: "artist")
        ]
        let playlist = controller(tracks)
        playlist.reorder(.title)
        #expect(playlist.playlist == [tracks[1], tracks[3], tracks[0], tracks[2]])
        #expect(tracks[1].playlistTitle == "Alpha - Zulu")
        #expect(track("/d", title: "Only title").playlistTitle == "Only title")
    }

    @Test("Title comparison ignores case and width and preserves ties")
    func titleTies() {
        let tracks = [track("/a", title: "Ａlpha 02"), track("/b", title: "alpha 2"), track("/c", title: "Alpha 10")]
        let playlist = controller(tracks)
        playlist.reorder(.title)
        #expect(playlist.playlist == tracks)
        #expect(PlaylistOrdering.title.compare(tracks[0], tracks[1]) == .orderedSame)
    }

    @Test("Filename sorting compares numeric runs before punctuation and letters")
    func filenames() {
        let tracks = ["/z/a10.mp3", "/a/a2.mp3", "/a/-intro.mp3", "/z/02.mp3", "/a/2.mp3", "/a/B.mp3"]
            .map { track($0, title: "Same title") }
        let playlist = controller(tracks)
        playlist.reorder(.filename)
        #expect(playlist.playlist == [tracks[3], tracks[4], tracks[2], tracks[1], tracks[0], tracks[5]])
        #expect(PlaylistOrdering.title.compare(track("/a", title: "2"), track("/b", title: "-")) == .orderedAscending)
    }

    @Test("Path sorting groups directories before comparing filenames")
    func directories() {
        let tracks = ["/music2/z10.mp3", "/music10/a.mp3", "/music2/z2.mp3", "/music2-extra/a.mp3", "/music2/z02.mp3"]
            .map { track($0) }
        let playlist = controller(tracks)
        playlist.reorder(.pathAndFilename)
        #expect(playlist.playlist == [tracks[2], tracks[4], tracks[0], tracks[3], tracks[1]])
    }

    @Test("Every command preserves current and selected identities, cursor and anchor", arguments: PlaylistOrdering.allCases)
    func identities(ordering: PlaylistOrdering) {
        let sharedURL = URL(fileURLWithPath: "/album.wav")
        let sheet = URL(fileURLWithPath: "/album.cue")
        let tracks = (0..<6).map { index in
            Track(url: sharedURL, title: "Track \(6 - index)", artist: "",
                  duration: 10, cueSlice: CueSlice(startTime: Double(index * 10), duration: 10,
                                                 cueSheetURL: sheet, trackNumber: index + 1))
        }
        let player = AudioPlayer()
        defer { player.stop() }
        tracks.forEach(player.playlistController.addTrack)
        player.currentTrack = tracks[2]
        player.updatePlaylistPosition(with: tracks[2])
        let state = player.playbackState
        player.currentTime = 3.5
        player.playbackProgress = 0.35
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [0, 2, 5]
        ui.cursorIndex = 2
        ui.anchorIndex = 5
        let actions = PlaylistWindowActions()
        actions.sortList(ordering, audioPlayer: player, interactionState: ui, visibleTrackCount: 2)
        #expect(Set(player.playlist.map(\.id)) == Set(tracks.map(\.id)))
        #expect(player.playlistController.currentTrack == tracks[2])
        #expect(player.currentTrack == tracks[2])
        #expect(player.playbackState == state)
        #expect(player.currentTime == 3.5)
        #expect(player.playbackProgress == 0.35)
        #expect(Set(ui.selectedIndices.map { player.playlist[$0].id }) == Set([0, 2, 5].map { tracks[$0].id }))
        #expect(ui.cursorIndex.map { player.playlist[$0].id } == tracks[2].id)
        #expect(ui.anchorIndex.map { player.playlist[$0].id } == tracks[5].id)
        #expect(actions.selectedIndices == ui.selectedIndices)
        let row = player.playlist.firstIndex(of: tracks[2])!
        #expect(ui.scrollOffsetPixels == CGFloat(min(row, 4)) * PlaylistWindowSizeState.trackRowHeight)
    }

    @Test("Reverse changes next-track routing while retaining the active local track")
    func navigation() throws {
        let remote = Track(url: try #require(URL(string: "https://example.com/live")), title: "Radio", artist: "", duration: 0)
        let current = track("/current.wav")
        let other = track("/other.wav")
        let playlist = controller([remote, current, other])
        playlist.updatePosition(with: current)
        playlist.reorder(.reverse)
        #expect(playlist.currentPosition == 2)
        #expect(playlist.nextTrack() == .requestCoordinatorPlayback(remote))
        playlist.reorder(.title)
        #expect(playlist.currentTrack == remote)
    }

    @Test("File sorts place locals before complete natural URL keys", arguments: [PlaylistOrdering.filename, .pathAndFilename])
    func remoteURLs(ordering: PlaylistOrdering) throws {
        let urls = [
            "custom://radio20/live",
            "ftp://radio2/live",
            "https://radio2.example/a?next=/zzz",
            "https://radio2.example/z",
            "https://radio2.example/z/",
            "https://radio2.example/z?part=2",
            "https://radio2.example/z?part=2/",
            "https://radio2.example/z?part=10",
            "https://radio10.example/a"
        ]
        let remotes = try urls.map { text in
            Track(url: try #require(URL(string: text)), title: "Radio", artist: "", duration: 0)
        }
        let locals = [track("/a/2.wav"), track("/z/10.wav")]
        let tracks = Array(remotes.reversed()) + locals.reversed()
        let player = AudioPlayer()
        defer { player.stop() }
        tracks.forEach(player.playlistController.addTrack)
        player.currentTrack = remotes[5]
        player.updatePlaylistPosition(with: remotes[5])
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = Set(tracks.indices.filter { tracks[$0] == remotes[5] || tracks[$0] == locals[0] })
        ui.cursorIndex = tracks.firstIndex(of: remotes[5])
        ui.anchorIndex = tracks.firstIndex(of: locals[0])
        PlaylistWindowActions().sortList(ordering, audioPlayer: player, interactionState: ui, visibleTrackCount: 4)
        #expect(player.playlist == locals + remotes)
        #expect(Array(player.playlist.dropFirst(2)).map { $0.url.absoluteString } == urls)
        #expect(player.currentTrack == remotes[5])
        #expect(player.playlistController.currentTrack == remotes[5])
        #expect(Set(ui.selectedIndices.map { player.playlist[$0].id }) == [locals[0].id, remotes[5].id])
        #expect(ui.cursorIndex == 7)
        #expect(ui.anchorIndex == 0)
    }

    @Test("Reordering a paused CUE run preserves time and rejects displaced slices", arguments: [PlaylistOrdering.reverse, .title])
    func pausedCueRun(ordering: PlaylistOrdering) throws {
        let root = try #require(UnitTestSupport.applicationSupportDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("ordering-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 6))
        buffer.frameLength = buffer.frameCapacity
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let tracks = (0..<3).map { index in
            Track(url: url, title: "Track \(index)", artist: "", duration: 2,
                  cueSlice: CueSlice(startTime: Double(index * 2), duration: 2,
                                     cueSheetURL: url.appendingPathExtension("cue"), trackNumber: index + 1))
        }
        let player = AudioPlayer()
        defer { player.stop() }
        tracks.forEach(player.playlistController.addTrack)
        player.playTrack(track: tracks[0])
        player.seek(to: 0.25, resume: false)
        #expect(player.isPaused)
        player.reorderPlaylist(ordering)
        #expect(player.currentTrack == tracks[0])
        #expect(player.isPaused)
        #expect(!player.isPlaying)
        #expect(player.currentTime == 0.25)
        player.engineForTesting.onProgressUpdate?(2.5, 0.4)
        #expect(player.currentTrack == (ordering == .reverse ? tracks[0] : tracks[1]))
    }

    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9e3779b97f4a7c15
            var value = state
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            return value ^ (value >> 31)
        }
    }

    @Test("Randomize changes order with a deterministic generator and preserves each entry")
    func randomize() {
        let tracks = (0..<12).map { track("/\($0).wav") }
        let first = controller(tracks)
        let second = controller(tracks)
        first.updatePosition(with: tracks[4])
        var firstGenerator = Generator(state: 42)
        var secondGenerator = Generator(state: 42)
        first.reorder(.randomize, using: &firstGenerator)
        second.reorder(.randomize, using: &secondGenerator)
        #expect(first.playlist != tracks)
        #expect(first.playlist == second.playlist)
        #expect(Set(first.playlist.map(\.id)) == Set(tracks.map(\.id)))
        #expect(first.currentTrack == tracks[4])
    }

    @Test("Reordering retains ended state and pending metadata identities")
    func pendingMetadataAndEndedState() {
        let tracks = [track("/b.wav", title: "B"), track("/a.wav", title: "A")]
        let playlist = controller(tracks)
        let savedRepeat = playlist.repeatMode
        playlist.repeatMode = .off
        defer { playlist.repeatMode = savedRepeat }
        playlist.updatePosition(with: tracks[1])
        #expect(playlist.nextTrack() == .endOfPlaylist)
        let pendingURL = URL(fileURLWithPath: "/pending.wav")
        playlist.addPendingURL(pendingURL)
        playlist.reorder(.title)
        #expect(playlist.hasEnded)
        #expect(playlist.currentTrack == nil)
        #expect(playlist.containsTrack(url: pendingURL))
        var loaded = tracks[0]
        loaded.title = "Loaded B"
        #expect(playlist.replacePlaceholder(id: tracks[0].id, with: loaded))
        #expect(playlist.playlist[1].title == "Loaded B")
    }

    @Test("Empty and singleton lists preserve interaction state", arguments: PlaylistOrdering.allCases)
    func shortLists(ordering: PlaylistOrdering) {
        for tracks in [[], [track("/single.wav", title: "One")]] {
            let player = AudioPlayer()
            defer { player.stop() }
            tracks.forEach(player.playlistController.addTrack)
            let ui = PlaylistWindowInteractionState()
            ui.selectedIndices = tracks.isEmpty ? [] : [0]
            ui.cursorIndex = tracks.isEmpty ? nil : 0
            ui.anchorIndex = ui.cursorIndex
            ui.scrollOffsetPixels = 11
            PlaylistWindowActions().sortList(ordering, audioPlayer: player, interactionState: ui, visibleTrackCount: 0)
            #expect(player.playlist == tracks)
            #expect(ui.selectedIndices == (tracks.isEmpty ? [] : [0]))
            #expect(ui.cursorIndex == (tracks.isEmpty ? nil : 0))
            #expect(ui.anchorIndex == ui.cursorIndex)
            #expect(ui.scrollOffsetPixels == 11)
        }
    }

    @Test("Reordering cancels stale dragging, drops invalid indices and scrolls an absent current position to zero")
    func staleInteraction() {
        let tracks = [track("/b.wav"), track("/a.wav")]
        let player = AudioPlayer()
        defer { player.stop() }
        tracks.forEach(player.playlistController.addTrack)
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [0, 1]
        ui.pressRow(index: 0, yFromTop: 2, windowY: 500)
        ui.selectedIndices.insert(99)
        ui.cursorIndex = -1
        ui.anchorIndex = 99
        ui.scrollOffsetPixels = 100
        PlaylistWindowActions().sortList(.reverse, audioPlayer: player, interactionState: ui, visibleTrackCount: 1)
        ui.dragRows(windowY: 400, viewportHeight: 200, maxScroll: 100) { _, _ in
            Issue.record("Reordering left a stale row drag active")
            return false
        }
        ui.releaseRow(windowY: 500)
        #expect(ui.selectedIndices == [0, 1])
        #expect(ui.cursorIndex == nil)
        #expect(ui.anchorIndex == nil)
        #expect(ui.scrollOffsetPixels == 0)
    }

    @Test("Sort submenu dispatches every command without opening a window")
    func menuDispatch() throws {
        let tracks = [track("/c/2.wav", title: "B"), track("/b/3.wav", title: "C"), track("/a/1.wav", title: "A")]
        for (index, ordering) in PlaylistOrdering.allCases.enumerated() {
            let player = AudioPlayer()
            defer { player.stop() }
            tracks.forEach(player.playlistController.addTrack)
            let ui = PlaylistWindowInteractionState()
            ui.selectedIndices = [0]
            let actions = PlaylistWindowActions.shared
            let savedSelection = actions.selectedIndices
            defer { actions.selectedIndices = savedSelection }
            let menu = PlaylistMenuPresenter.makeSortMenu(audioPlayer: player, interactionState: ui, visibleTrackCount: 2)
            #expect(menu.items.map(\.title) == [
                "Sort list by title", "Sort list by filename", "Sort list by path and filename", "", "Reverse list", "Randomize list"
            ])
            #expect(menu.items[3].isSeparatorItem)
            let item = menu.items[index < 3 ? index : index + 1]
            #expect(item.keyEquivalent.isEmpty)
            try #require(item.target as? MenuActionTarget).execute()
            switch ordering {
            case .title: #expect(player.playlist == [tracks[2], tracks[0], tracks[1]])
            case .filename: #expect(player.playlist == [tracks[2], tracks[0], tracks[1]])
            case .pathAndFilename: #expect(player.playlist == [tracks[2], tracks[1], tracks[0]])
            case .reverse: #expect(player.playlist == tracks.reversed())
            case .randomize: #expect(Set(player.playlist.map(\.id)) == Set(tracks.map(\.id)))
            }
            #expect(ui.selectedIndices.map { player.playlist[$0] } == [tracks[0]])
            #expect(actions.selectedIndices == ui.selectedIndices)
        }
    }
}
