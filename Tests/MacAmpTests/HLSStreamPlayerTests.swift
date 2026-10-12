import Foundation
import Testing
@testable import MacAmp

/// Pausing a live HLS stream stops it, and resuming starts it again at the live edge: it has no
/// connection to hold, and the audio it paused on is gone from the live window.
@MainActor
@Suite("HLS stream player", .tags(.audio), .serialized)
struct HLSStreamPlayerTests {

    private let playlistURL = URL(string: "https://edge.example.com/hls/live/96k.m3u8")!

    private func makePlayer() throws -> (player: StreamPlayer, origin: HLSTestOrigin) {
        let url = try #require(Fixtures.url("hls-segment", withExtension: "ts"))
        let segment = try Data(contentsOf: url)
        let origin = HLSTestOrigin(playlists: [HLSTestOrigin.playlist(from: 1, count: 8)]) { _ in (segment, 200) }
        let player = StreamPlayer()
        let first = origin.firstPlaylist
        player.pipelineForTesting.playlistFetch = { requested in
            (Data(first.utf8), HTTPURLResponse(url: requested, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        player.pipelineForTesting.hlsFetch = { origin.respond($0) }
        return (player, origin)
    }

    private func wait(timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func isPlaying(_ player: StreamPlayer) -> Bool {
        if case .playing = player.pipelineStateForTesting { return true }
        return false
    }

    @Test("Pausing an HLS stream stops it, keeps the station, tears the bridge down, and does not reconnect")
    func pauseStops() async throws {
        let (player, _) = try makePlayer()
        var teardowns = 0
        player.onStreamTerminated = { teardowns += 1 }
        await player.play(station: RadioStation(name: "Live", streamURL: playlistURL))
        #expect(await wait { isPlaying(player) })

        player.pause()
        await player.drainTransportChainForTesting()

        #expect(player.pipelineForTesting.isHLS == false)
        if case .idle = player.pipelineStateForTesting {} else { Issue.record("expected .idle, got \(player.pipelineStateForTesting)") }
        #expect(player.userPausedForTesting)
        #expect(player.isPlaying == false)
        #expect(player.isBuffering == false)
        #expect(player.currentStation != nil)
        #expect(teardowns == 1)
        #expect(player.attemptReconnectInvocationCountForTesting == 0)
    }

    @Test("Resuming starts a fresh stream whose audio goes into a new ring buffer")
    func resumeRestarts() async throws {
        let (player, _) = try makePlayer()
        await player.play(station: RadioStation(name: "Live", streamURL: playlistURL))
        #expect(await wait { isPlaying(player) })
        let oldRing = try #require(player.pipelineForTesting.ringBuffer)

        player.pause()
        player.resume()
        await player.drainTransportChainForTesting()

        #expect(await wait { isPlaying(player) })
        let newRing = try #require(player.pipelineForTesting.ringBuffer)
        #expect(newRing !== oldRing)
        #expect(player.pipelineStartInvocationCountForTesting == 1)
        #expect(await wait { newRing.writeHeadFrames > 0 })
        #expect(player.userPausedForTesting == false)
    }

    @Test("Rapid pause and resume cycles end in a single running stream")
    func rapidCycles() async throws {
        let (player, _) = try makePlayer()
        var teardowns = 0
        player.onStreamTerminated = { teardowns += 1 }
        await player.play(station: RadioStation(name: "Live", streamURL: playlistURL))
        #expect(await wait { isPlaying(player) })

        for _ in 0..<5 {
            player.pause()
            player.resume()
        }
        await player.drainTransportChainForTesting()

        #expect(await wait { isPlaying(player) })
        let ring = try #require(player.pipelineForTesting.ringBuffer)
        #expect(await wait { ring.writeHeadFrames > 0 })
        #expect(player.pipelineForTesting.isHLS)
        #expect(player.userPausedForTesting == false)
        player.stop()
        #expect(teardowns >= 1)
    }

    @Test("After a pause and resume the engine plays the new ring buffer")
    func engineConsumesReplacementRing() async throws {
        let url = try #require(Fixtures.url("hls-segment", withExtension: "ts"))
        let segment = try Data(contentsOf: url)
        let origin = HLSTestOrigin(playlists: [HLSTestOrigin.playlist(from: 1, count: 8)]) { _ in (segment, 200) }
        let audioPlayer = AudioPlayer()
        let streamPlayer = StreamPlayer()
        let coordinator = PlaybackCoordinator(audioPlayer: audioPlayer, streamPlayer: streamPlayer)
        let first = origin.firstPlaylist
        streamPlayer.pipelineForTesting.playlistFetch = { requested in
            (Data(first.utf8), HTTPURLResponse(url: requested, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        streamPlayer.pipelineForTesting.hlsFetch = { origin.respond($0) }
        defer {
            streamPlayer.stop()
            withExtendedLifetime(coordinator) {}
        }

        await streamPlayer.play(station: RadioStation(name: "Live", streamURL: playlistURL))
        let oldRing = try #require(streamPlayer.pipelineForTesting.ringBuffer)
        #expect(await wait { audioPlayer.isBridgeActive && oldRing.readHeadFrames > 0 })

        streamPlayer.pause()
        #expect(audioPlayer.isBridgeActive == false)
        streamPlayer.resume()
        await streamPlayer.drainTransportChainForTesting()

        #expect(await wait { isPlaying(streamPlayer) })
        let newRing = try #require(streamPlayer.pipelineForTesting.ringBuffer)
        #expect(newRing !== oldRing)
        #expect(await wait { audioPlayer.isBridgeActive && newRing.readHeadFrames > 0 })
    }
}
