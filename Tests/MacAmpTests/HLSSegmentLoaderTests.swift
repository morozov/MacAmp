import Foundation
import Testing
@testable import MacAmp

@Suite("HLS segment loader", .tags(.audio, .parsing))
struct HLSSegmentLoaderTests {
    private let playlistURL = URL(string: "https://edge.example.com/hls/main/96k.m3u8")!

    // MARK: - Test doubles

    /// A clock that only moves when the loader sleeps or the test advances it.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var time = 0.0
        private var slept: [Double] = []

        var now: Double { lock.withLock { time } }
        var sleeps: [Double] { lock.withLock { slept } }

        func sleep(_ seconds: Double) {
            lock.withLock {
                time += seconds
                slept.append(seconds)
            }
        }

        func advance(_ seconds: Double) {
            lock.withLock { time += seconds }
        }
    }

    /// A scripted server: each playlist request takes the next playlist of the script,
    /// repeating the last one. Segments are the bytes of their own name.
    private final class FakeServer: @unchecked Sendable {
        private let lock = NSLock()
        private var playlists: [String]
        private var playlistRequests = 0
        private var requested: [URL] = []
        var segmentStatus: [String: Int] = [:]
        var playlistStatuses: [Int] = []
        var failure: (any Error)?

        init(_ playlists: [String]) { self.playlists = playlists }

        var urls: [URL] { lock.withLock { requested } }
        var playlistCount: Int { lock.withLock { playlistRequests } }

        func script(_ playlists: [String]) {
            lock.withLock {
                self.playlists = playlists
                playlistRequests = 0
            }
        }

        /// Playlist requests answer as if redirected here.
        var redirectPlaylistsTo: URL?
        /// Segment names whose first request waits until its task is cancelled.
        var hangOnce: Set<String> = []
        /// Segment names whose first request returns normally but cancels its own task.
        var cancelAfterReturning: Set<String> = []
        private var hanging: Set<String> = []

        /// Wait until a request for `name` is waiting in `hangOnce`.
        func waitForHang(_ name: String) async throws {
            for _ in 0..<1000 {
                if lock.withLock({ hanging.contains(name) }) { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw CancellationError()
        }

        func respond(_ url: URL) async throws -> (data: Data, status: Int, url: URL) {
            let name = url.lastPathComponent
            let hang = lock.withLock { () -> Bool in
                guard hangOnce.remove(name) != nil else { return false }
                hanging.insert(name)
                return true
            }
            if hang { try await Task.sleep(for: .seconds(1000)) }
            let cancelNow = lock.withLock { cancelAfterReturning.remove(name) != nil }
            defer { if cancelNow { withUnsafeCurrentTask { $0?.cancel() } } }
            return try lock.withLock {
                requested.append(url)
                if let failure { throw failure }
                if url.pathExtension == "m3u8" {
                    let index = playlistRequests
                    playlistRequests += 1
                    if index < playlistStatuses.count, playlistStatuses[index] != 200 {
                        return (Data(), playlistStatuses[index], url)
                    }
                    let text = playlists[min(index, playlists.count - 1)]
                    return (Data(text.utf8), 200, redirectPlaylistsTo ?? url)
                }
                let name = url.lastPathComponent
                return (Data(name.utf8), segmentStatus[name] ?? 200, url)
            }
        }
    }

    private func playlist(
        from first: Int,
        count: Int,
        target: Int = 5,
        ended: Bool = false,
        discontinuityBefore: Set<Int> = []
    ) -> String {
        var text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:\(first)\n"
        for sequence in first..<(first + count) {
            if discontinuityBefore.contains(sequence) { text += "#EXT-X-DISCONTINUITY\n" }
            text += "#EXTINF:\(target).000,\ns\(sequence).ts\n"
        }
        if ended { text += "#EXT-X-ENDLIST\n" }
        return text
    }

    private func loader(_ server: FakeServer, _ clock: FakeClock) -> HLSSegmentLoader {
        HLSSegmentLoader(
            playlistURL: playlistURL,
            fetch: { try await server.respond($0) },
            sleep: { clock.sleep($0) },
            now: { clock.now }
        )
    }

    private func take(_ count: Int, from loader: HLSSegmentLoader) async throws -> [HLSSegmentLoader.Segment] {
        var segments: [HLSSegmentLoader.Segment] = []
        for _ in 0..<count {
            guard let segment = try await loader.next() else { break }
            segments.append(segment)
        }
        return segments
    }

    // MARK: - Start position

    @Test("Playback starts three target durations behind the live end")
    func startsBehindLive() async throws {
        let server = FakeServer([playlist(from: 100, count: 6)])
        let segments = try await take(3, from: loader(server, FakeClock()))
        #expect(segments.map(\.sequence) == [103, 104, 105])
    }

    @Test("A four-segment window starts at its second segment")
    func startsInsideShortWindow() async throws {
        let server = FakeServer([playlist(from: 10, count: 4)])
        #expect(try await take(1, from: loader(server, FakeClock())).first?.sequence == 11)
    }

    @Test("A window shorter than three target durations starts at its oldest segment")
    func startsAtOldestWhenShort() async throws {
        let server = FakeServer([playlist(from: 7, count: 2)])
        #expect(try await take(1, from: loader(server, FakeClock())).first?.sequence == 7)
    }

    @Test("Segment URIs resolve against the playlist URL and each is fetched once")
    func resolvesURIs() async throws {
        let server = FakeServer([playlist(from: 100, count: 4)])
        _ = try await take(3, from: loader(server, FakeClock()))
        let segmentURLs = server.urls.filter { $0.pathExtension == "ts" }.map(\.absoluteString)
        #expect(segmentURLs == (101...103).map { "https://edge.example.com/hls/main/s\($0).ts" })
    }

    // MARK: - Sequencing

    @Test("New segments are delivered once and in order across playlist refreshes")
    func deliversInOrder() async throws {
        let server = FakeServer([playlist(from: 100, count: 4), playlist(from: 102, count: 4)])
        let segments = try await take(5, from: loader(server, FakeClock()))
        #expect(segments.map(\.sequence) == [101, 102, 103, 104, 105])
        #expect(segments.map { String(decoding: $0.data, as: UTF8.self) } == (101...105).map { "s\($0).ts" })
        #expect(segments.allSatisfy { !$0.followsDiscontinuity })
    }

    @Test("A playlist discontinuity tag flags the segment after it")
    func playlistDiscontinuity() async throws {
        let server = FakeServer([playlist(from: 100, count: 4, discontinuityBefore: [102])])
        let segments = try await take(3, from: loader(server, FakeClock()))
        #expect(segments.map(\.followsDiscontinuity) == [false, true, false])
    }

    @Test("Segments that fell out of the window are skipped and the next one is flagged")
    func windowSlidesPast() async throws {
        let server = FakeServer([playlist(from: 100, count: 4), playlist(from: 110, count: 4)])
        let segments = try await take(5, from: loader(server, FakeClock()))
        #expect(segments.map(\.sequence) == [101, 102, 103, 110, 111])
        #expect(segments.map(\.followsDiscontinuity) == [false, false, false, true, false])
    }

    @Test("A playlist that starts over resumes at its live edge and flags the join")
    func playlistRestart() async throws {
        let server = FakeServer([playlist(from: 100, count: 4), playlist(from: 5, count: 4)])
        let segments = try await take(4, from: loader(server, FakeClock()))
        #expect(segments.map(\.sequence) == [101, 102, 103, 6])
        #expect(segments.last?.followsDiscontinuity == true)
    }

    @Test("ENDLIST finishes the stream after the last segment")
    func endListFinishes() async throws {
        let server = FakeServer([playlist(from: 100, count: 4), playlist(from: 100, count: 4, ended: true)])
        let streamLoader = loader(server, FakeClock())
        #expect(try await take(3, from: streamLoader).count == 3)
        #expect(try await streamLoader.next() == nil)
    }

    @Test("An on-demand playlist is rejected")
    func onDemandRejected() async {
        let server = FakeServer([playlist(from: 0, count: 4, ended: true)])
        await #expect(throws: HLSSegmentLoader.LoadError.onDemand) {
            _ = try await loader(server, FakeClock()).next()
        }
    }

    @Test("A master playlist is not a media playlist")
    func masterRejected() async {
        let server = FakeServer(["#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=64000\nv.m3u8\n"])
        do {
            _ = try await loader(server, FakeClock()).next()
            Issue.record("expected an error")
        } catch let error as HLSSegmentLoader.LoadError {
            guard case .invalidPlaylist = error else { Issue.record("wrong error \(error)"); return }
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    // MARK: - Waiting and stalls

    @Test("A playlist that stops offering segments stalls after three target durations")
    func stalls() async throws {
        let server = FakeServer([playlist(from: 100, count: 4)])
        let clock = FakeClock()
        let streamLoader = loader(server, clock)
        _ = try await take(3, from: streamLoader)

        await #expect(throws: HLSSegmentLoader.LoadError.stalled) {
            _ = try await streamLoader.next()
        }
        #expect(clock.sleeps.allSatisfy { $0 == 2.5 })
        #expect(clock.sleeps.reduce(0, +) > 15)
    }

    @Test("Time the caller spends away is not a stall")
    func timeAwayIsNotAStall() async throws {
        let server = FakeServer([playlist(from: 100, count: 4)])
        let clock = FakeClock()
        let streamLoader = loader(server, clock)
        _ = try await take(3, from: streamLoader)

        // After the gap, the first refresh finds nothing new and the second finds a segment.
        clock.advance(500)
        server.script([playlist(from: 100, count: 4), playlist(from: 102, count: 4)])
        #expect(try await streamLoader.next()?.sequence == 104)
        #expect(server.playlistCount == 2)
    }

    // MARK: - Failures

    @Test("A missing playlist fails at once")
    func playlistNotFound() async {
        let server = FakeServer([playlist(from: 100, count: 4)])
        server.playlistStatuses = [404]
        await #expect(throws: HLSSegmentLoader.LoadError.http(404)) {
            _ = try await loader(server, FakeClock()).next()
        }
        #expect(server.playlistCount == 1)
    }

    @Test("429 and 5xx responses are retried with backoff, then succeed")
    func transientStatusRetries() async throws {
        let server = FakeServer([playlist(from: 100, count: 4)])
        server.playlistStatuses = [429, 503, 200]
        let clock = FakeClock()
        #expect(try await take(1, from: loader(server, clock)).count == 1)
        #expect(clock.sleeps == [0.5, 1])
    }

    @Test("A persistent 5xx fails after the retries")
    func persistentServerError() async {
        let server = FakeServer([playlist(from: 100, count: 4)])
        server.playlistStatuses = [500, 500, 500, 500, 500]
        let clock = FakeClock()
        await #expect(throws: HLSSegmentLoader.LoadError.http(500)) {
            _ = try await loader(server, clock).next()
        }
        #expect(server.playlistCount == 4)
        #expect(clock.sleeps == [0.5, 1, 2])
    }

    @Test("Network errors are reported with their code after the retries")
    func networkError() async {
        let server = FakeServer([playlist(from: 100, count: 4)])
        server.failure = URLError(.timedOut)
        await #expect(throws: (any Error).self) {
            _ = try await loader(server, FakeClock()).next()
        }
        do {
            _ = try await loader(server, FakeClock()).next()
        } catch let error as HLSSegmentLoader.LoadError {
            guard case .network(_, let code) = error else { Issue.record("wrong error \(error)"); return }
            #expect(code == URLError.timedOut.rawValue)
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test("A segment the server no longer has is skipped and the next one is flagged")
    func segmentGone() async throws {
        let server = FakeServer([playlist(from: 100, count: 4)])
        server.segmentStatus["s102.ts"] = 404
        let segments = try await take(2, from: loader(server, FakeClock()))
        #expect(segments.map(\.sequence) == [101, 103])
        #expect(segments.map(\.followsDiscontinuity) == [false, true])
    }

    @Test("Cancelling stops a loader that is waiting for new segments")
    func cancellation() async throws {
        let server = FakeServer([playlist(from: 100, count: 4)])
        let streamLoader = HLSSegmentLoader(
            playlistURL: playlistURL,
            fetch: { try await server.respond($0) },
            sleep: { try await Task.sleep(for: .seconds($0 * 1000)) }
        )
        _ = try await take(3, from: streamLoader)

        let waiting = Task { try await streamLoader.next() }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
    }

    @Test("A cancelled download is retried by the next call, not lost")
    func cancelledDownloadIsKept() async throws {
        let server = FakeServer([playlist(from: 100, count: 4)])
        server.hangOnce = ["s101.ts"]
        let streamLoader = loader(server, FakeClock())

        let first = Task { try await streamLoader.next() }
        try await server.waitForHang("s101.ts")
        first.cancel()
        await #expect(throws: CancellationError.self) { _ = try await first.value }

        let segments = try await take(3, from: streamLoader)
        #expect(segments.map(\.sequence) == [101, 102, 103])
        #expect(segments.allSatisfy { !$0.followsDiscontinuity })
    }

    @Test("A second pull while one is outstanding is refused")
    func overlappingPullRefused() async throws {
        let server = FakeServer([playlist(from: 100, count: 4)])
        server.hangOnce = ["s101.ts"]
        let streamLoader = loader(server, FakeClock())

        let outstanding = Task { try await streamLoader.next() }
        try await server.waitForHang("s101.ts")
        await #expect(throws: HLSSegmentLoader.LoadError.overlappingPull) { _ = try await streamLoader.next() }
        outstanding.cancel()
        _ = try? await outstanding.value
    }

    @Test("Relative segment URIs resolve against the playlist's final URL after a redirect")
    func redirectedPlaylistBase() async throws {
        let server = FakeServer([playlist(from: 100, count: 4)])
        server.redirectPlaylistsTo = URL(string: "https://cdn.example.net/live/96k.m3u8")
        _ = try await take(1, from: loader(server, FakeClock()))
        #expect(server.urls.last?.absoluteString == "https://cdn.example.net/live/s101.ts")
    }

    @Test("A live playlist that starts empty is still live when its last segments arrive with ENDLIST")
    func emptyThenEnded() async throws {
        let server = FakeServer([playlist(from: 100, count: 0), playlist(from: 100, count: 3, ended: true)])
        let streamLoader = loader(server, FakeClock())
        #expect(try await take(3, from: streamLoader).map(\.sequence) == [100, 101, 102])
        #expect(try await streamLoader.next() == nil)
    }

    @Test("A restart with a different target duration changes the polling and stall timing")
    func restartUpdatesTiming() async throws {
        let server = FakeServer([playlist(from: 100, count: 4)])
        let clock = FakeClock()
        let streamLoader = loader(server, clock)
        _ = try await take(3, from: streamLoader)

        server.script([playlist(from: 5, count: 4, target: 30)])
        #expect(try await take(3, from: streamLoader).map(\.sequence) == [6, 7, 8])
        await #expect(throws: HLSSegmentLoader.LoadError.stalled) { _ = try await streamLoader.next() }
        #expect(clock.sleeps.allSatisfy { $0 == 15 })
        #expect(clock.sleeps.reduce(0, +) > 90)
    }

    @Test("A download that succeeds after cancellation keeps the pending discontinuity marker")
    func cancelledSuccessKeepsMarker() async throws {
        let server = FakeServer([playlist(from: 100, count: 4), playlist(from: 110, count: 4)])
        let streamLoader = loader(server, FakeClock())
        _ = try await take(3, from: streamLoader)

        server.cancelAfterReturning = ["s110.ts"]
        let cancelled = Task { try await streamLoader.next() }
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }

        let segment = try await streamLoader.next()
        #expect(segment?.sequence == 110)
        #expect(segment?.followsDiscontinuity == true)
    }

    @Test("A garbled playlist is invalid; a feature the loader cannot play is unsupported")
    func invalidAndUnsupported() async {
        let garbled = FakeServer(["<html><body>502 Bad Gateway</body></html>"])
        do {
            _ = try await loader(garbled, FakeClock()).next()
            Issue.record("expected an error")
        } catch let error as HLSSegmentLoader.LoadError {
            guard case .invalidPlaylist = error else { Issue.record("wrong error \(error)"); return }
        } catch {
            Issue.record("wrong error \(error)")
        }

        let encrypted = FakeServer(["#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXT-X-KEY:METHOD=AES-128,URI=\"k\"\n#EXTINF:5.0,\na.ts\n"])
        do {
            _ = try await loader(encrypted, FakeClock()).next()
            Issue.record("expected an error")
        } catch let error as HLSSegmentLoader.LoadError {
            guard case .unsupported = error else { Issue.record("wrong error \(error)"); return }
        } catch {
            Issue.record("wrong error \(error)")
        }
    }
}
