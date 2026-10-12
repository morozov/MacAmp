import Foundation
import Testing
@testable import MacAmp

/// Runs a live HLS playlist through `StreamDecodePipeline` with scripted fetches: the segments
/// are a real captured AAC transport stream segment, decoded by the same parser, converter and
/// ring buffer an ICY stream uses.
@MainActor
@Suite("HLS stream pipeline", .tags(.audio), .serialized)
struct HLSStreamPipelineTests {
    private final class BundleToken {}

    private let playlistURL = URL(string: "https://edge.example.com/hls/live/96k.m3u8")!
    /// Frames in one fixture segment: 40 AAC frames of 1,024 samples.
    private let framesPerSegment = 40 * 1024

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: name, withExtension: "ts"))
        return try Data(contentsOf: url)
    }

    /// A scripted origin. Each media-playlist request takes the next playlist of the script,
    /// repeating the last one. Segments answer with `segment(named)`.
    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var playlists: [String]
        /// What the first look at the playlist URL sees, before the loader starts.
        let firstPlaylist: String
        private var playlistRequests = 0
        private var requested: [URL] = []
        let segment: @Sendable (String) -> (Data, Int)

        init(playlists: [String], segment: @escaping @Sendable (String) -> (Data, Int)) {
            self.playlists = playlists
            self.firstPlaylist = playlists[0]
            self.segment = segment
        }

        var urls: [URL] { lock.withLock { requested } }

        func respond(_ url: URL) -> (data: Data, status: Int, url: URL) {
            lock.withLock {
                requested.append(url)
                if url.pathExtension == "m3u8" {
                    let text = playlists[min(playlistRequests, playlists.count - 1)]
                    playlistRequests += 1
                    return (Data(text.utf8), 200, url)
                }
                let (data, status) = segment(url.lastPathComponent)
                return (data, status, url)
            }
        }
    }

    private func playlist(from first: Int, count: Int, ended: Bool = false, discontinuityBefore: Set<Int> = []) -> String {
        var text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:\(first)\n"
        for sequence in first..<(first + count) {
            if discontinuityBefore.contains(sequence) { text += "#EXT-X-DISCONTINUITY\n" }
            text += "#EXTINF:1.000,\nseg\(sequence).ts\n"
        }
        if ended { text += "#EXT-X-ENDLIST\n" }
        return text
    }

    private struct Run {
        let pipeline: StreamDecodePipeline
        let ring: LockFreeRingBuffer
        let server: Server
    }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var terminations: [StreamDecodePipeline.StreamTerminationReason] = []
        private var rates: [Float64] = []
        var termination: [StreamDecodePipeline.StreamTerminationReason] { lock.withLock { terminations } }
        var formatRates: [Float64] { lock.withLock { rates } }
        func add(_ reason: StreamDecodePipeline.StreamTerminationReason) { lock.withLock { terminations.append(reason) } }
        func add(rate: Float64) { lock.withLock { rates.append(rate) } }
    }

    private func start(
        server: Server,
        capacity: Int = 480_000,
        resolve: String? = nil,
        events: Events
    ) -> Run {
        let pipeline = StreamDecodePipeline()
        let resolveText = resolve ?? server.firstPlaylist
        pipeline.playlistFetch = { requested in
            (Data(resolveText.utf8), HTTPURLResponse(url: requested, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        pipeline.hlsFetch = { server.respond($0) }
        pipeline.onFormatReady = { events.add(rate: $0) }
        pipeline.onTermination = { events.add($0) }
        let ring = LockFreeRingBuffer(capacity: capacity, channelCount: 2)
        pipeline.start(url: playlistURL, ringBuffer: ring)
        return Run(pipeline: pipeline, ring: ring, server: server)
    }

    private func wait(timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: - Playback

    @Test("A live HLS playlist plays: audio reaches the ring and the stream becomes ready")
    func playsLivePlaylist() async throws {
        let segment = try fixture("hls-segment")
        let server = Server(playlists: [playlist(from: 1, count: 8)]) { _ in (segment, 200) }
        let events = Events()
        let run = start(server: server, events: events)
        defer { run.pipeline.stop() }

        #expect(await wait { run.ring.writeHeadFrames >= UInt64(framesPerSegment * 3) })
        #expect(run.pipeline.isHLS)
        #expect(events.formatRates == [44100])
        #expect(events.termination.isEmpty)
        if case .playing = run.pipeline.state {} else { Issue.record("expected .playing, got \(run.pipeline.state)") }
    }

    @Test("A master playlist streams from its audio-only variant")
    func masterPlaylist() async throws {
        let segment = try fixture("hls-segment")
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=900000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=640x360
        video.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=96000,CODECS="mp4a.40.2"
        audio/96k.m3u8
        """
        let server = Server(playlists: [playlist(from: 1, count: 8)]) { _ in (segment, 200) }
        let events = Events()
        let run = start(server: server, resolve: master, events: events)
        defer { run.pipeline.stop() }

        #expect(await wait { run.ring.writeHeadFrames >= UInt64(framesPerSegment) })
        let playlists = server.urls.filter { $0.pathExtension == "m3u8" }
        #expect(playlists.first?.absoluteString == "https://edge.example.com/hls/live/audio/96k.m3u8")
    }

    @Test("A discontinuity in the playlist does not interrupt playback")
    func discontinuity() async throws {
        let segment = try fixture("hls-segment")
        // Playback starts at sequence 6 of 1...8, so the decoder exists before the discontinuity
        // at 7 reopens the parser and restarts the converter on the same format.
        let server = Server(playlists: [playlist(from: 1, count: 8, discontinuityBefore: [7])]) { _ in (segment, 200) }
        let events = Events()
        let run = start(server: server, events: events)
        defer { run.pipeline.stop() }

        #expect(await wait { run.ring.writeHeadFrames >= UInt64(framesPerSegment * 3) })
        #expect(events.termination.isEmpty)
        #expect(events.formatRates == [44100])
    }

    // MARK: - Backpressure

    @Test("The ring does not overflow, and playback resumes as the ring drains")
    func backpressure() async throws {
        let segment = try fixture("hls-segment")
        let server = Server(playlists: [playlist(from: 1, count: 8)]) { _ in (segment, 200) }
        let events = Events()
        // Room for about 2.3 segments, so the half-full gate holds the feeder back.
        let capacity = framesPerSegment * 2 + 15_000
        let run = start(server: server, capacity: capacity, events: events)
        defer { run.pipeline.stop() }

        #expect(await wait { run.ring.writeHeadFrames >= UInt64(framesPerSegment) })
        try await Task.sleep(for: .milliseconds(600))
        #expect(run.ring.telemetry().overruns == 0)
        // Held at the half-full gate plus the one chunk in flight, well short of the suspend mark.
        #expect(run.ring.availableFrames <= capacity / 2 + 20_000)
        let heldAt = run.ring.writeHeadFrames

        // Drain what is there; the feeder wakes and the ring fills again.
        var scratch = [Float](repeating: 0, count: 8192 * 2)
        while run.ring.availableFrames > 0 {
            _ = scratch.withUnsafeMutableBufferPointer { run.ring.read(into: $0.baseAddress!, frameCount: 8192) }
        }
        #expect(await wait { run.ring.writeHeadFrames > heldAt + UInt64(framesPerSegment / 2) })
        #expect(run.ring.telemetry().overruns == 0)
    }

    @Test("Near-silent AAC, which packs seconds of audio into a few kilobytes, still fits the ring")
    func silentAACStaysWithinTheRing() async throws {
        let segment = try fixture("hls-segment-silent")
        let server = Server(playlists: [playlist(from: 1, count: 8)]) { _ in (segment, 200) }
        let events = Events()
        // A 4 KB chunk of this audio decodes to about six times the ring.
        let capacity = 100_000
        let run = start(server: server, capacity: capacity, events: events)
        defer { run.pipeline.stop() }

        #expect(await wait { run.ring.writeHeadFrames >= UInt64(capacity / 2) })
        try await Task.sleep(for: .milliseconds(500))
        #expect(run.ring.telemetry().overruns == 0)
        #expect(run.ring.availableFrames <= capacity)
        let heldAt = run.ring.writeHeadFrames

        var scratch = [Float](repeating: 0, count: 8192 * 2)
        while run.ring.availableFrames > 0 {
            _ = scratch.withUnsafeMutableBufferPointer { run.ring.read(into: $0.baseAddress!, frameCount: 8192) }
        }
        #expect(await wait { run.ring.writeHeadFrames > heldAt + UInt64(capacity / 4) })
        #expect(run.ring.telemetry().overruns == 0)
        #expect(events.termination.isEmpty)
    }

    // MARK: - Ending and failing

    @Test("A playlist that ends closes the stream like a server closing an ICY connection")
    func endList() async throws {
        let segment = try fixture("hls-segment")
        let live = playlist(from: 1, count: 4)
        let ended = playlist(from: 1, count: 4, ended: true)
        let server = Server(playlists: [live, ended]) { _ in (segment, 200) }
        let events = Events()
        let run = start(server: server, resolve: live, events: events)
        defer { run.pipeline.stop() }

        #expect(await wait { !events.termination.isEmpty })
        guard case .serverClosed? = events.termination.first else {
            Issue.record("expected serverClosed, got \(events.termination)")
            return
        }
        if case .idle = run.pipeline.state {} else { Issue.record("expected .idle, got \(run.pipeline.state)") }
    }

    @Test("A missing media playlist ends the stream with a client error")
    func playlistMissing() async throws {
        let events = Events()
        let live = playlist(from: 1, count: 4)
        let missing = playlistURL
        let pipeline = StreamDecodePipeline()
        pipeline.playlistFetch = { requested in
            (Data(live.utf8), HTTPURLResponse(url: requested, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        pipeline.hlsFetch = { _ in (Data(), 404, missing) }
        pipeline.onTermination = { events.add($0) }
        pipeline.start(url: playlistURL, ringBuffer: LockFreeRingBuffer(capacity: 480_000, channelCount: 2))
        defer { pipeline.stop() }

        #expect(await wait { !events.termination.isEmpty })
        guard case .httpClientError(404)? = events.termination.first else {
            Issue.record("expected httpClientError(404), got \(events.termination)")
            return
        }
    }

    @Test("Playlists the player cannot play end the stream without a reconnect")
    func unsupportedPlaylists() async throws {
        let cases = [
            "#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXT-X-KEY:METHOD=AES-128,URI=\"k\"\n#EXTINF:5.0,\na.ts\n",
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=900000,CODECS=\"avc1.4d401f,mp4a.40.2\"\nv.m3u8\n",
            "#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXTINF:5.0,\na.ts\n#EXT-X-ENDLIST\n",
        ]
        for text in cases {
            let events = Events()
            let pipeline = StreamDecodePipeline()
            pipeline.playlistFetch = { requested in
                (Data(text.utf8), HTTPURLResponse(url: requested, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            pipeline.hlsFetch = { requested in (Data(text.utf8), 200, requested) }
            pipeline.onTermination = { events.add($0) }
            pipeline.start(url: playlistURL, ringBuffer: LockFreeRingBuffer(capacity: 480_000, channelCount: 2))
            defer { pipeline.stop() }

            #expect(await wait { !events.termination.isEmpty })
            guard case .decodeError? = events.termination.first else {
                Issue.record("expected decodeError for \(text), got \(events.termination)")
                continue
            }
        }
    }

    @Test("A change of audio format mid-stream ends the stream")
    func formatChange() async throws {
        let first = try fixture("hls-segment")
        let other = try fixture("hls-segment-48k")
        // The stream switches to 48 kHz at sequence 7, announced by a discontinuity.
        let server = Server(playlists: [playlist(from: 1, count: 8, discontinuityBefore: [7])]) { name in
            (name == "seg7.ts" || name == "seg8.ts" ? other : first, 200)
        }
        let events = Events()
        let run = start(server: server, events: events)
        defer { run.pipeline.stop() }

        #expect(await wait { !events.termination.isEmpty })
        guard case .decodeError(let message)? = events.termination.first else {
            Issue.record("expected decodeError, got \(events.termination)")
            return
        }
        #expect(message == "HLS audio format changed")
        // Only the segment before the change was decoded: the old converter never saw the new audio.
        #expect(run.ring.writeHeadFrames == UInt64(framesPerSegment))
    }

    @Test("A garbled playlist is a passing fault and may be retried; an unsupported one may not")
    func garbledAndUnsupportedRefreshes() async throws {
        let live = playlist(from: 1, count: 4)
        let cases: [(refresh: String, retriable: Bool)] = [
            ("<html><body>502 Bad Gateway</body></html>", true),
            ("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXT-X-KEY:METHOD=AES-128,URI=\"k\"\n#EXTINF:1.0,\na.ts\n", false),
        ]
        for (refresh, retriable) in cases {
            let events = Events()
            let pipeline = StreamDecodePipeline()
            pipeline.playlistFetch = { requested in
                (Data(live.utf8), HTTPURLResponse(url: requested, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            pipeline.hlsFetch = { requested in (Data(refresh.utf8), 200, requested) }
            pipeline.onTermination = { events.add($0) }
            pipeline.start(url: playlistURL, ringBuffer: LockFreeRingBuffer(capacity: 480_000, channelCount: 2))
            defer { pipeline.stop() }

            #expect(await wait { !events.termination.isEmpty })
            switch events.termination.first {
            case .playlistResolutionFailed? where retriable: break
            case .decodeError? where !retriable: break
            default: Issue.record("unexpected \(events.termination) for \(refresh.prefix(30))")
            }
        }
    }

    @Test("A malformed HLS playlist at the start is retried, unlike an unsupported one")
    func malformedAtStart() async throws {
        let malformed = [
            "#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXT-X-MEDIA-SEQUENCE:99999999999999999999999\n#EXTINF:5.0,\na.ts\n",
            "#EXTM3U\n#EXT-X-TARGETDURATION\n#EXTINF:5.0,\na.ts\n",
        ]
        for text in malformed {
            let events = Events()
            let pipeline = StreamDecodePipeline()
            pipeline.playlistFetch = { requested in
                (Data(text.utf8), HTTPURLResponse(url: requested, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            pipeline.onTermination = { events.add($0) }
            pipeline.start(url: playlistURL, ringBuffer: LockFreeRingBuffer(capacity: 480_000, channelCount: 2))
            defer { pipeline.stop() }

            #expect(await wait { !events.termination.isEmpty })
            guard case .playlistResolutionFailed? = events.termination.first else {
                Issue.record("expected playlistResolutionFailed, got \(events.termination) for \(text.prefix(60))")
                continue
            }
        }
    }

    // MARK: - Stopping

    @Test("Releasing the pipeline cancels its loader")
    func releaseCancelsLoader() async throws {
        let segment = try fixture("hls-segment")
        let server = Server(playlists: [playlist(from: 1, count: 8)]) { _ in (segment, 200) }
        var run: Run? = start(server: server, events: Events())

        #expect(await wait { (run?.ring.writeHeadFrames ?? 0) >= UInt64(framesPerSegment) })
        run = nil
        try await Task.sleep(for: .milliseconds(100))
        let fetched = server.urls.count
        try await Task.sleep(for: .milliseconds(1300))
        #expect(server.urls.count == fetched)
    }

    @Test("Stopping cancels the loader: nothing more is fetched")
    func stopCancelsLoader() async throws {
        let segment = try fixture("hls-segment")
        let server = Server(playlists: [playlist(from: 1, count: 8)]) { _ in (segment, 200) }
        let events = Events()
        let run = start(server: server, events: events)

        #expect(await wait { run.ring.writeHeadFrames >= UInt64(framesPerSegment) })
        run.pipeline.stop()
        #expect(run.pipeline.isHLS == false)
        let fetched = server.urls.count
        // Longer than two playlist polls (half the one-second target each).
        try await Task.sleep(for: .milliseconds(1300))
        #expect(server.urls.count == fetched)
    }
}
