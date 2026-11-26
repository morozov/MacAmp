import AVFoundation
import Foundation
import Testing
@testable import MacAmp

@MainActor
@Suite("Playlist title rebuilding", .timeLimit(.minutes(1)))
struct PlaylistTitleRebuildTests {
    private func track(_ name: String) -> Track {
        Track(url: URL(fileURLWithPath: "/music/\(name).wav"), title: name, artist: "Artist", duration: 42)
    }

    private func player(_ tracks: [Track]) -> AudioPlayer {
        let player = AudioPlayer()
        tracks.forEach(player.playlistController.addTrack)
        return player
    }

    @Test("Selected rows refresh in playlist order while the loaded source snapshot stays intact")
    func selectionAndPlayback() async {
        let tracks = [track("A"), track("B"), track("C")]
        let player = player(tracks)
        player.selectTrackForPlayback(tracks[1])
        player.currentTime = 7
        let state = player.playbackState
        var loaded: [URL] = []
        await player.rebuildPlaylistTitles(ids: [tracks[2].id, tracks[1].id], loadMetadata: { url in
            loaded.append(url)
            return .init(title: "Rebuilt \(url.lastPathComponent)", artist: "New artist", duration: 123)
        }).value
        #expect(loaded == [tracks[1].url, tracks[2].url])
        #expect(player.playlist.map(\.id) == tracks.map(\.id))
        #expect(player.playlist.map(\.url) == tracks.map(\.url))
        #expect(player.playlist.map(\.title) == ["A", "Rebuilt B.wav", "Rebuilt C.wav"])
        #expect(player.playlist.map(\.duration) == [42, 123, 123])
        #expect(player.playlist[1].artist == "New artist")
        #expect(player.currentTrack?.title == tracks[1].title)
        #expect(player.currentDuration == 42)
        #expect(player.currentTime == 7)
        #expect(player.playlistPosition == 2)
        #expect(player.playbackState == state)
    }

    @Test("An empty or obsolete selection performs no metadata loading")
    func emptySelection() async {
        let player = player([track("A")])
        for ids in [[], [UUID()]] {
            await player.rebuildPlaylistTitles(ids: ids, loadMetadata: { _ in
                Issue.record("No row should load")
                return .init(title: "Wrong", artist: "", duration: 0)
            }).value
        }
        #expect(player.playlist[0].title == "A")
    }

    @Test("Rebuild results follow identities through reordering and skip removed targets")
    func reorderedTargets() async {
        let tracks = [track("A"), track("B"), track("C")]
        let player = player(tracks)
        let gate = RebuildMetadataGate()
        var loads: [URL] = []
        let task = player.rebuildPlaylistTitles(ids: tracks.map(\.id), loadMetadata: { url in
            loads.append(url)
            return await gate.load(url)
        })
        await gate.waitUntilStarted()
        player.reorderPlaylist(.reverse)
        player.removeTrack(at: 1)
        gate.finish(title: "Fresh")
        await task.value
        #expect(player.playlist.map(\.id) == [tracks[2].id, tracks[0].id])
        #expect(player.playlist.allSatisfy { $0.title == "Fresh" })
        #expect(loads == [tracks[0].url, tracks[2].url])
    }

    @Test("Removal, replacement, edits and later rebuilds reject old results", arguments: ["remove", "replace", "edit", "rebuild"])
    func supersededResults(_ operation: String) async {
        let original = track("A")
        let player = player([original])
        let gate = RebuildMetadataGate()
        let task = player.rebuildPlaylistTitles(ids: [original.id], loadMetadata: gate.load)
        await gate.waitUntilStarted()
        switch operation {
        case "remove": player.removeTrack(at: 0)
        case "replace": player.replacePlaylist(with: [original])
        case "edit":
            await player.editPlaylistEntry(id: original.id, expectedURL: original.url,
                                           url: URL(fileURLWithPath: "/music/new.wav"), loadMetadata: { _ in
                .init(title: "Newest", artist: "", duration: 10)
            })?.value
        default:
            await player.rebuildPlaylistTitles(ids: [original.id], loadMetadata: { _ in
                .init(title: "Newest", artist: "", duration: 10)
            }).value
        }
        gate.finish(title: "Obsolete")
        await task.value
        #expect(!player.playlist.contains { $0.title == "Obsolete" })
        if operation == "replace" { #expect(player.playlist[0].title == "A") }
        if operation == "edit" || operation == "rebuild" { #expect(player.playlist[0].title == "Newest") }
        if operation == "remove" { #expect(player.playlist.isEmpty) }
    }

    @Test("Rebuilding supersedes an entry edit's pending metadata")
    func supersededEdit() async {
        let original = track("A")
        let player = player([original])
        let gate = RebuildMetadataGate()
        let url = URL(fileURLWithPath: "/music/new.wav")
        let edit = player.editPlaylistEntry(id: original.id, expectedURL: original.url, url: url, loadMetadata: gate.load)
        await gate.waitUntilStarted()
        await player.rebuildPlaylistTitles(ids: [original.id], loadMetadata: { _ in
            .init(title: "Fresh", artist: "New artist", duration: 99)
        }).value
        gate.finish(title: "Obsolete")
        await edit?.value
        #expect(player.playlist[0].url == url)
        #expect(player.playlist[0].title == "Fresh")
        #expect(player.playlist[0].duration == 99)
    }

    @Test("Rebuilding an initial placeholder releases its pending URL reservation")
    func pendingInitialURL() async throws {
        let player = AudioPlayer()
        let url = URL(fileURLWithPath: "/music/pending.wav")
        let gate = RebuildMetadataGate()
        let initial = try #require(player.addTrack(url: url, loadMetadata: gate.load))
        await gate.waitUntilStarted()
        let id = try #require(player.playlist.first?.id)
        await player.rebuildPlaylistTitles(ids: [id], loadMetadata: { _ in
            .init(title: "Fresh", artist: "", duration: 99)
        }).value
        gate.finish(title: "Obsolete")
        await initial.value
        #expect(player.playlist[0].id == id)
        #expect(player.playlist[0].title == "Fresh")
        player.removeTrack(at: 0)
        let readded = try #require(player.addTrack(url: url, loadMetadata: { _ in
            .init(title: "Added again", artist: "", duration: 99)
        }))
        await readded.value
        #expect(player.playlist[0].title == "Added again")
    }

    @Test("Streams use received titles for a matching loaded URL and never load local metadata")
    func streams() async throws {
        let url = try #require(URL(string: "https://example.com/live?q=one#station"))
        let otherURL = try #require(URL(string: "https://example.com/other?q=two#station"))
        let tracks = [Track(url: url, title: "Label A", artist: "Old", duration: 0),
                      Track(url: url, title: "Label B", artist: "Old", duration: 42),
                      Track(url: otherURL, title: "Other station", artist: "Old", duration: 42)]
        let player = player(tracks)
        let loader: (URL) async -> MetadataLoader.TrackMetadata = { _ in
            Issue.record("A stream must not fetch local metadata")
            return .init(title: "Wrong", artist: "Wrong", duration: 99)
        }
        await player.rebuildPlaylistTitles(ids: tracks.map(\.id), activeStream: (url, "Artist - Song"), loadMetadata: loader).value
        #expect(player.playlist.map(\.title) == ["Artist - Song", "Artist - Song", otherURL.absoluteString])
        #expect(player.playlist.allSatisfy { $0.artist.isEmpty && $0.duration == 0 })
        await player.rebuildPlaylistTitles(ids: tracks.map(\.id), loadMetadata: loader).value
        #expect(player.playlist.map(\.title) == [url.absoluteString, url.absoluteString, otherURL.absoluteString])
        #expect(player.playlist.map(\.id) == tracks.map(\.id))
    }

    @Test("A missing file uses the existing metadata fallback")
    func missingFile() async throws {
        let root = try #require(UnitTestSupport.applicationSupportDirectory)
        let missing = Track(url: root.appendingPathComponent("missing-\(UUID().uuidString).wav"),
                            title: "Old", artist: "Old", duration: 42)
        let player = player([missing])
        await player.rebuildPlaylistTitles(ids: [missing.id]).value
        #expect(player.playlist[0].title == missing.url.lastPathComponent)
        #expect(player.playlist[0].artist == "Unknown")
        #expect(player.playlist[0].duration == 0)
        #expect(player.playlist[0].url == missing.url)
    }

    @Test("CUE rebuilds preserve exact row duration, slice bounds and provenance")
    func cueMetadata() async {
        var original = track("Slice")
        original.duration = 1.75
        original.cueSlice = CueSlice(startTime: 2, duration: 2,
                                     cueSheetURL: URL(fileURLWithPath: "/music/album.cue"), trackNumber: 2)
        let player = player([original])
        await player.rebuildPlaylistTitles(ids: [original.id], loadMetadata: { _ in
            .init(title: "Backing title", artist: "Backing artist", duration: 100)
        }).value
        #expect(player.playlist[0].title == "Backing title")
        #expect(player.playlist[0].artist == "Backing artist")
        #expect(player.playlist[0].id == original.id)
        #expect(player.playlist[0].url == original.url)
        #expect(player.playlist[0].duration == original.duration)
        #expect(player.playlist[0].cueSlice == original.cueSlice)
    }

    @Test("Rebuilding CUE metadata preserves a paused scheduled run and later slice playback")
    func loadedCueRun() async throws {
        let root = try #require(UnitTestSupport.applicationSupportDirectory)
        let folder = root.appendingPathComponent("rebuild-cue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("album.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 6))
        buffer.frameLength = buffer.frameCapacity
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let tracks = (0..<3).map { index in
            Track(url: url, title: "Slice \(index)", artist: "Sheet artist", duration: 2,
                  cueSlice: CueSlice(startTime: Double(index * 2), duration: 2,
                                     cueSheetURL: folder.appendingPathComponent("album.cue"), trackNumber: index + 1))
        }
        let player = player(tracks)
        defer { player.stop() }
        player.playTrack(track: tracks[0])
        player.seek(to: 0.25, resume: false)
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [0, 1]
        ui.cursorIndex = 1
        ui.anchorIndex = 0
        await PlaylistWindowActions().rebuildTitles(audioPlayer: player, interactionState: ui, loadMetadata: { _ in
            .init(title: "Backing title", artist: "Backing artist", duration: 99)
        }).value
        #expect(player.playlist.map(\.title) == ["Backing title", "Backing title", "Slice 2"])
        #expect(player.playlist.map(\.duration) == [2, 2, 2])
        #expect(player.playlist.map(\.cueSlice) == tracks.map(\.cueSlice))
        #expect(player.currentTrack?.title == "Slice 0")
        #expect(player.currentTrack?.id == tracks[0].id)
        #expect(player.currentTime == 0.25)
        #expect(player.currentDuration == 2)
        #expect(player.isPaused)
        #expect(player.engineForTesting.audioFile?.url == url)
        #expect(ui.selectedIndices == [0, 1])
        #expect(ui.cursorIndex == 1)
        #expect(ui.anchorIndex == 0)
        player.engineForTesting.onProgressUpdate?(2.5, 0.4)
        #expect(player.currentTrack?.id == tracks[1].id)
        #expect(player.currentTrack?.title == "Slice 1")
        player.stop()
        player.playTrack(track: player.playlist[1])
        #expect(player.currentTrack?.title == "Backing title")
        #expect(player.currentDuration == 2)
        #expect(player.currentTrack?.cueSlice?.startTime == 2)
        #expect(player.engineForTesting.audioFile?.url == url)
    }
}

@MainActor
private final class RebuildMetadataGate {
    private let stream: AsyncStream<MetadataLoader.TrackMetadata>
    private let continuation: AsyncStream<MetadataLoader.TrackMetadata>.Continuation
    private let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private var metadata: MetadataLoader.TrackMetadata?

    init() {
        (stream, continuation) = AsyncStream.makeStream()
        (started, startedContinuation) = AsyncStream.makeStream()
    }

    func load(_ url: URL) async -> MetadataLoader.TrackMetadata {
        startedContinuation.yield(())
        if let metadata { return metadata }
        var iterator = stream.makeAsyncIterator()
        return await iterator.next() ?? .init(title: "", artist: "", duration: 0)
    }

    func waitUntilStarted() async {
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
    }

    func finish(title: String) {
        let result = MetadataLoader.TrackMetadata(title: title, artist: "Loaded artist", duration: 90)
        metadata = result
        continuation.yield(result)
        continuation.finish()
    }
}
