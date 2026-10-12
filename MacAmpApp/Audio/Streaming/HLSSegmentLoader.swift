import Foundation

/// Downloads the segments of a live HLS media playlist, one at a time and in order.
///
/// The caller pulls: `next()` fetches a segment only when asked, so a caller that is
/// paused or holding back for a full buffer costs no downloads. While the playlist has
/// nothing new, `next()` polls it about every half target duration.
actor HLSSegmentLoader {
    struct Segment: Equatable, Sendable {
        let data: Data
        let sequence: UInt64
        /// The audio before this segment is not contiguous with it: the playlist said so,
        /// or segments were skipped.
        let followsDiscontinuity: Bool
    }

    enum LoadError: Error, Equatable {
        /// A request failed with this HTTP status.
        case http(Int)
        /// A request failed before a response, with the `NSURLError` code.
        case network(String, Int)
        /// The playlist stopped offering new segments.
        case stalled
        /// The playlist is on-demand, which is not supported.
        case onDemand
        /// The playlist could not be read, or is not the kind of playlist expected here.
        case invalidPlaylist(String)
        /// The playlist uses a feature this loader does not support, such as encryption.
        case unsupported(String)
        /// `next()` was called again before the previous call returned.
        case overlappingPull
    }

    /// The response body, its HTTP status, and the URL it finally came from, which
    /// differs from the request after a redirect.
    typealias Fetch = @Sendable (URL) async throws -> (data: Data, status: Int, url: URL)
    typealias Sleep = @Sendable (Double) async throws -> Void

    /// Waits between retries of a failed request, in seconds.
    private static let retryDelays: [Double] = [0.5, 1, 2]
    /// How far behind the live end playback starts, in target durations (RFC 8216 6.3.3).
    private static let startBehindLive = 3.0
    /// How long without a new segment, in target durations, before the stream is stalled.
    private static let stallTolerance = 3.0

    private let playlistURL: URL
    private let fetch: Fetch
    private let sleep: Sleep
    private let now: @Sendable () -> Double

    private var pending: [HLSPlaylist.Segment] = []
    private var nextSequence: UInt64?
    private var targetDuration: Double = 0
    private var ended = false
    private var skippedSegments = false
    /// Whether a media playlist has been read, even one with no segments yet.
    private var initialized = false
    /// Where relative segment URIs resolve from: the playlist's final URL after redirects.
    private var baseURL: URL
    private var pulling = false

    init(
        playlistURL: URL,
        fetch: @escaping Fetch = HLSSegmentLoader.fetchWithURLSession,
        sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) },
        now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.playlistURL = playlistURL
        self.baseURL = playlistURL
        self.fetch = fetch
        self.sleep = sleep
        self.now = now
    }

    /// The next segment, or nil when the playlist has ended and every segment was delivered.
    ///
    /// Calls must not overlap: an actor lets a second call run while the first waits, which
    /// could deliver segments out of order. An overlapping call throws `overlappingPull`.
    func next() async throws -> Segment? {
        guard !pulling else { throw LoadError.overlappingPull }
        pulling = true
        defer { pulling = false }

        // Time the caller spends away, paused or holding back, does not count as a stall.
        var lastProgress = now()
        while true {
            try Task.checkCancellation()

            // An entry leaves `pending` only once it is delivered or deliberately skipped,
            // so a cancelled download is retried by the next call.
            while let entry = pending.first {
                let segment = try await download(entry)
                try Task.checkCancellation()
                pending.removeFirst()
                if let segment {
                    skippedSegments = false
                    return segment
                }
            }
            if ended { return nil }

            try await refresh()
            if !pending.isEmpty {
                lastProgress = now()
                continue
            }
            if ended { return nil }

            if now() - lastProgress > Self.stallTolerance * targetDuration {
                throw LoadError.stalled
            }
            try await sleep(max(targetDuration / 2, 0.5))
        }
    }

    // MARK: - Playlist

    private func refresh() async throws {
        let (data, finalURL) = try await fetchWithRetry(playlistURL)
        baseURL = finalURL
        guard let text = String(data: data, encoding: .utf8) else {
            throw LoadError.invalidPlaylist("Unable to read playlist file")
        }
        let playlist: HLSPlaylist
        do {
            playlist = try HLSPlaylist.parse(text, relativeTo: baseURL)
        } catch HLSPlaylist.ParseError.unsupportedEncryption {
            throw LoadError.unsupported("Encrypted HLS streams are not supported")
        } catch HLSPlaylist.ParseError.unsupportedInitSegment {
            throw LoadError.unsupported("HLS streams with initialization segments are not supported")
        } catch HLSPlaylist.ParseError.unsupportedByteRange {
            throw LoadError.unsupported("HLS streams with byte ranges are not supported")
        } catch {
            throw LoadError.invalidPlaylist("\(error)")
        }
        guard case .media(let media) = playlist else {
            throw LoadError.invalidPlaylist("Expected a media playlist")
        }

        if !initialized {
            if media.isEnded { throw LoadError.onDemand }
            initialized = true
        }
        targetDuration = media.targetDuration
        if nextSequence == nil {
            nextSequence = startSequence(in: media)
        }
        ended = media.isEnded

        guard var wanted = nextSequence else { return }

        // A playlist that now ends before the sequence we want has started over.
        if let last = media.segments.last, last.sequence &+ 1 < wanted {
            wanted = startSequence(in: media) ?? wanted
            skippedSegments = true
        }

        let fresh = media.segments.filter { $0.sequence >= wanted }
        if let first = fresh.first, first.sequence > wanted {
            skippedSegments = true
        }
        guard let last = fresh.last else {
            nextSequence = wanted
            return
        }
        let (following, overflow) = last.sequence.addingReportingOverflow(1)
        if overflow { throw LoadError.invalidPlaylist("Media sequence overflow") }
        pending.append(contentsOf: fresh)
        nextSequence = following
    }

    /// The sequence of the first segment to play: the one that leaves three target
    /// durations before the live end, or the oldest listed.
    private func startSequence(in media: HLSPlaylist.Media) -> UInt64? {
        var behind = 0.0
        var start = media.segments.last
        for segment in media.segments.reversed() {
            start = segment
            behind += segment.duration
            if behind >= Self.startBehindLive * media.targetDuration { break }
        }
        return start?.sequence
    }

    // MARK: - Segments

    /// The downloaded segment, or nil when the server no longer has it.
    private func download(_ entry: HLSPlaylist.Segment) async throws -> Segment? {
        let data: Data
        do {
            data = try await fetchWithRetry(entry.url).data
        } catch LoadError.http(let status) where status == 404 || status == 410 {
            // The live window moved past it before we got there.
            skippedSegments = true
            return nil
        }
        // The skip marker is cleared by the caller once the segment is committed.
        let discontinuity = entry.followsDiscontinuity || skippedSegments
        return Segment(data: data, sequence: entry.sequence, followsDiscontinuity: discontinuity)
    }

    // MARK: - Requests

    /// Fetch `url`, retrying transient failures (network errors, 429, 5xx) with backoff.
    private func fetchWithRetry(_ url: URL) async throws -> (data: Data, url: URL) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let failure: LoadError
            do {
                let (data, status, finalURL) = try await fetch(url)
                if (200...299).contains(status) { return (data, finalURL) }
                if !(status == 429 || status >= 500) { throw LoadError.http(status) }
                failure = .http(status)
            } catch let error as LoadError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                failure = .network(error.localizedDescription, (error as NSError).code)
            }

            guard attempt < Self.retryDelays.count else { throw failure }
            try await sleep(Self.retryDelays[attempt])
            attempt += 1
        }
    }

    static let fetchWithURLSession: Fetch = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http.statusCode, http.url ?? url)
    }
}
