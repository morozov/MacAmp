import AVFoundation
import Foundation
import Testing
@testable import MacAmp

@MainActor
@Suite("Playlist Entry editing", .timeLimit(.minutes(1)))
struct PlaylistEntryEditingTests {
    private func track(_ name: String) -> Track {
        Track(url: URL(fileURLWithPath: "/music/\(name).wav"), title: name, artist: "Artist", duration: 42)
    }

    @Test("Metadata completion keeps the placeholder identity and current playlist position")
    func placeholderIdentity() async throws {
        let player = AudioPlayer()
        let url = URL(fileURLWithPath: "/music/pending.wav")
        let task = try #require(player.addTrack(url: url, loadMetadata: { _ in
            .init(title: "Loaded", artist: "Artist", duration: 10)
        }))
        let placeholder = try #require(player.playlist.first)
        player.selectTrackForPlayback(placeholder)
        await task.value
        #expect(player.playlist[0].id == placeholder.id)
        #expect(player.playlist[0].title == "Loaded")
        #expect(player.currentTrack?.id == placeholder.id)
        #expect(player.playlistPosition == 1)
    }

    @Test("An edited or removed placeholder cannot be replaced or appended by its initial load",
          arguments: [false, true])
    func staleInitialMetadata(remove: Bool) async throws {
        let player = AudioPlayer()
        let gate = DeferredMetadata()
        let original = URL(fileURLWithPath: "/music/pending.wav")
        let task = try #require(player.addTrack(url: original, loadMetadata: gate.load))
        let placeholder = try #require(player.playlist.first)
        let replacement = try #require(URL(string: "https://example.com/live"))
        if remove {
            player.removeTrack(at: 0)
        } else {
            await player.editPlaylistEntry(id: placeholder.id, expectedURL: original, url: replacement)?.value
        }
        gate.finish(title: "Obsolete")
        await task.value
        #expect(player.playlist.count == (remove ? 0 : 1))
        #expect(!player.playlist.contains(where: { $0.url == original }))
        if !remove {
            #expect(player.playlist[0].id == placeholder.id)
            #expect(player.playlist[0].url == replacement)
            #expect(player.playlist[0].title == replacement.absoluteString)
        }
    }

    @Test("A later edit supersedes metadata even when the URL changes back")
    func supersededEdit() async throws {
        let player = AudioPlayer()
        let original = track("A")
        player.playlistController.addTrack(original)
        let gate = DeferredMetadata()
        let secondURL = URL(fileURLWithPath: "/music/B.wav")
        let firstEdit = player.editPlaylistEntry(id: original.id, expectedURL: original.url,
                                          url: secondURL, loadMetadata: gate.load)
        #expect(player.playlist[0].title == "B.wav")
        #expect(player.playlist[0].artist.isEmpty)
        #expect(player.playlist[0].duration == original.duration)
        await player.editPlaylistEntry(id: original.id, expectedURL: secondURL, url: original.url,
                                       loadMetadata: { _ in .init(title: "Newest", artist: "Newest artist", duration: 99) })?.value
        gate.finish(title: "Obsolete")
        await firstEdit?.value
        #expect(player.playlist[0].url == original.url)
        #expect(player.playlist[0].title == "Newest")
        #expect(player.playlist[0].artist == "Newest artist")
        #expect(player.playlist[0].duration == original.duration)
    }

    @Test("An edited placeholder releases its old URL without cancelling a newer add")
    func readdOriginalURL() async throws {
        let player = AudioPlayer()
        let oldGate = DeferredMetadata()
        let newGate = DeferredMetadata()
        let url = URL(fileURLWithPath: "/music/pending.wav")
        let first = try #require(player.addTrack(url: url, loadMetadata: oldGate.load))
        let id = try #require(player.playlist.first?.id)
        await player.editPlaylistEntry(id: id, expectedURL: url, url: try #require(URL(string: "https://example.com/live")))?.value
        let second = try #require(player.addTrack(url: url, loadMetadata: newGate.load))
        let secondID = try #require(player.playlist.last?.id)
        oldGate.finish(title: "Obsolete")
        await first.value
        #expect(player.playlist.count == 2)
        #expect(player.playlist[1].artist == "Loading...")
        #expect(player.addTrack(url: url, loadMetadata: newGate.load) == nil)
        newGate.finish(title: "Newest")
        await second.value
        #expect(player.playlist[0].id == id)
        #expect(player.playlist[1].id == secondID)
        #expect(player.playlist[1].title == "Newest")
    }

    @Test("An edited loading placeholder receives duration from its replacement metadata")
    func editedPlaceholderDuration() async throws {
        let player = AudioPlayer()
        let initialGate = DeferredMetadata()
        let originalURL = URL(fileURLWithPath: "/music/original.wav")
        let initial = try #require(player.addTrack(url: originalURL, loadMetadata: initialGate.load))
        let id = try #require(player.playlist.first?.id)
        await player.editPlaylistEntry(id: id, expectedURL: originalURL,
                                       url: URL(fileURLWithPath: "/music/replacement.wav"),
                                       loadMetadata: { _ in .init(title: "Replacement", artist: "", duration: 123) })?.value
        initialGate.finish(title: "Obsolete")
        await initial.value
        #expect(player.playlist[0].id == id)
        #expect(player.playlist[0].duration == 123)
        #expect(player.playlist[0].title == "Replacement")
    }

    @Test("Removing or re-editing a metadata refresh keeps another pending URL reserved", arguments: [false, true])
    func pendingURLKinds(remove: Bool) async {
        let player = AudioPlayer()
        let original = track("A")
        player.playlistController.addTrack(original)
        let sharedURL = URL(fileURLWithPath: "/music/pending.wav")
        let gate = DeferredMetadata()
        let edit = player.editPlaylistEntry(id: original.id, expectedURL: original.url,
                                          url: sharedURL, loadMetadata: gate.load)
        player.playlistController.addPendingURL(sharedURL)
        if remove {
            player.removeTrack(at: 0)
        } else {
            await player.editPlaylistEntry(id: original.id, expectedURL: sharedURL,
                                           url: URL(fileURLWithPath: "/music/final.wav"),
                                           loadMetadata: { _ in .init(title: "Newest", artist: "", duration: 20) })?.value
        }
        #expect(player.playlistController.containsTrack(url: sharedURL))
        gate.finish(title: "Obsolete")
        await edit?.value
        #expect(player.playlistController.containsTrack(url: sharedURL))
        player.playlistController.removePendingURL(sharedURL)
        #expect(!player.playlistController.containsTrack(url: sharedURL))
    }

    @Test("A stream entry edited to a local file receives its unknown duration", arguments: [false, true])
    func unknownStreamDuration(fromPlaceholder: Bool) async throws {
        let player = AudioPlayer()
        let remoteURL = try #require(URL(string: "https://example.com/live"))
        let gate = DeferredMetadata()
        let initial: Task<Void, Never>?
        let id: UUID
        if fromPlaceholder {
            let url = URL(fileURLWithPath: "/music/initial.wav")
            initial = try #require(player.addTrack(url: url, loadMetadata: gate.load))
            id = try #require(player.playlist.first?.id)
            await player.editPlaylistEntry(id: id, expectedURL: url, url: remoteURL)?.value
        } else {
            let stream = Track(url: remoteURL, title: "Station", artist: "", duration: 0)
            player.addStreamTrack(stream)
            id = stream.id
            initial = nil
        }
        let localURL = URL(fileURLWithPath: "/music/replacement.wav")
        await player.editPlaylistEntry(id: id, expectedURL: remoteURL, url: localURL,
                                       loadMetadata: { _ in .init(title: "Local file", artist: "", duration: 73) })?.value
        gate.finish(title: "Obsolete")
        await initial?.value
        #expect(player.playlist[0].id == id)
        #expect(player.playlist[0].url == localURL)
        #expect(player.playlist[0].duration == 73)
        #expect(player.playlist[0].title == "Local file")
    }

    @Test("Removed rows and expected-URL mismatches reject late edit results")
    func removedEdit() async {
        let player = AudioPlayer()
        let original = track("A")
        let survivor = track("C")
        [original, survivor].forEach(player.playlistController.addTrack)
        let gate = DeferredMetadata()
        let url = URL(fileURLWithPath: "/music/B.wav")
        let edit = player.editPlaylistEntry(id: original.id, expectedURL: original.url, url: url, loadMetadata: gate.load)
        player.removeTrack(at: 0)
        gate.finish(title: "Obsolete")
        await edit?.value
        #expect(player.playlist.map(\.id) == [survivor.id])
        let accepted = player.editPlaylistEntry(id: survivor.id, expectedURL: original.url, url: url)
        #expect(accepted == nil)
        #expect(player.playlist[0].url == survivor.url)
    }

    @Test("A stopped restart resolves the edited row while the source snapshot remains unchanged")
    func restartTarget() async throws {
        let player = AudioPlayer()
        let coordinator = PlaybackCoordinator(audioPlayer: player, streamPlayer: StreamPlayer())
        let original = track("A")
        player.playlistController.addTrack(original)
        coordinator.selectTrack(original)
        let url = try #require(URL(string: "https://example.com/live?q=1#station"))
        await player.editPlaylistEntry(id: original.id, expectedURL: original.url, url: url)?.value
        #expect(coordinator.currentTrack?.url == original.url)
        #expect(coordinator.currentPlaylistTrack?.url == url)
        #expect(coordinator.currentPlaylistTrack?.isStream == true)
        #expect(coordinator.currentSource == nil)
    }

    @Test("Local CUE edits retain bounds and rejected stream edits preserve the loaded run", arguments: ["http", "https"])
    func cueBounds(scheme: String) async throws {
        let root = try #require(UnitTestSupport.applicationSupportDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent("entry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let firstURL = folder.appendingPathComponent("first.wav")
        let secondURL = folder.appendingPathComponent("second.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 6))
        buffer.frameLength = buffer.frameCapacity
        for url in [firstURL, secondURL] {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let tracks = (0..<3).map { index in
            Track(url: firstURL, title: "Slice \(index)", artist: "", duration: 2,
                  cueSlice: CueSlice(startTime: Double(index * 2), duration: 2,
                                     cueSheetURL: folder.appendingPathComponent("album.cue"), trackNumber: index + 1))
        }
        let player = AudioPlayer()
        defer { player.stop() }
        tracks.forEach(player.playlistController.addTrack)
        player.playTrack(track: tracks[0])
        player.seek(to: 0.25, resume: false)
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [1]
        ui.cursorIndex = 1
        ui.anchorIndex = 1
        let before = player.playlist[1]
        var rejectedLoads = 0
        let rejected = player.editPlaylistEntry(
            id: tracks[1].id, expectedURL: firstURL, url: try #require(URL(string: "\(scheme)://example.com/live")),
            loadMetadata: { _ in rejectedLoads += 1; return .init(title: "Wrong", artist: "", duration: 0) }
        )
        #expect(rejected == nil)
        #expect(rejectedLoads == 0)
        #expect(player.playlist[1].id == before.id)
        #expect(player.playlist[1].url == before.url)
        #expect(player.playlist[1].title == before.title)
        #expect(player.playlist[1].artist == before.artist)
        #expect(player.playlist[1].duration == before.duration)
        #expect(player.playlist[1].cueSlice == before.cueSlice)
        #expect(player.engineForTesting.audioFile?.url == firstURL)
        #expect(player.currentTrack?.url == firstURL)
        #expect(player.currentTime == 0.25)
        #expect(player.isPaused)
        #expect(ui.selectedIndices == [1])
        #expect(ui.cursorIndex == 1)
        #expect(ui.anchorIndex == 1)
        player.engineForTesting.onProgressUpdate?(2.5, 0.4)
        #expect(player.currentTrack?.id == tracks[1].id)
        player.playTrack(track: tracks[0])
        player.seek(to: 0.25, resume: false)
        await player.editPlaylistEntry(id: tracks[1].id, expectedURL: firstURL, url: secondURL,
                                       loadMetadata: { _ in .init(title: "Replacement", artist: "", duration: 6) })?.value
        #expect(player.playlist[1].cueSlice == tracks[1].cueSlice)
        #expect(player.playlist[1].duration == 2)
        #expect(player.playlist[0].url == firstURL)
        #expect(player.playlist[2].url == firstURL)
        #expect(player.currentTrack?.url == firstURL)
        #expect(player.currentTime == 0.25)
        #expect(player.isPaused)
        player.engineForTesting.onProgressUpdate?(2.5, 0.4)
        #expect(player.currentTrack?.id == tracks[0].id)
        player.stop()
        player.playTrack(track: player.playlist[1])
        #expect(player.currentTrack?.url == secondURL)
        #expect(player.engineForTesting.audioFile?.url == secondURL)
        #expect(player.currentTrack?.cueSlice?.startTime == 2)
    }
}

@MainActor
private final class DeferredMetadata {
    private let stream: AsyncStream<MetadataLoader.TrackMetadata>
    private let continuation: AsyncStream<MetadataLoader.TrackMetadata>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func load(_ url: URL) async -> MetadataLoader.TrackMetadata {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next() ?? .init(title: "", artist: "", duration: 0)
    }

    func finish(title: String) {
        continuation.yield(.init(title: title, artist: "Loaded artist", duration: 90))
        continuation.finish()
    }
}
