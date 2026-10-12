import Foundation
import AudioToolbox
@preconcurrency import os
#if SWIFT_PACKAGE
import AudioWorkgroupShim
#endif

/// Orchestrates the full stream decode chain:
/// `URLSession → ICYFramer → AudioFileStreamParser → AudioConverterDecoder → LockFreeRingBuffer`
///
/// **Architecture:**
/// - `@MainActor` class for lifecycle/state management (matches PlaybackCoordinator pattern)
/// - `DecodeContext` (@unchecked Sendable, queue-confined) owns all decode-queue state
/// - NSObject delegate proxy forwards URLSession bytes to decode queue
/// - Callbacks to StreamPlayer are `@MainActor @Sendable`
///
/// **Threading:**
/// ```
/// Main Thread (@MainActor)     Decode Queue (serial)     Audio IO Thread (RT)
/// ├─ start()/stop()/pause()    ├─ ICYFramer              ├─ AVAudioSourceNode
/// ├─ state callbacks           ├─ AudioFileStreamParser   │  render block
/// └─ UI updates                ├─ AudioConverterDecoder   │  ringBuffer.read()
///                              └─ ringBuffer.write()  ──►│
/// ```
///
/// **Layer:** Mechanism (orchestrator, owns decode chain lifecycle)
@MainActor
final class StreamDecodePipeline {

    // MARK: - Stream State

    enum StreamState: Sendable {
        case idle
        case connecting
        case buffering
        case playing
        case paused
        case error(String)
    }

    /// Typed reason for stream termination — used by StreamPlayer for reconnect policy.
    /// Mechanism layer classifies the cause; policy layer decides whether to retry.
    enum StreamTerminationReason: Sendable {
        case networkError(String, Int)     // URLSession error (message + NSURLError code) — reconnectable for transient errors
        case serverClosed                 // Server closed connection — reconnectable
        case httpClientError(Int)         // 4xx — NOT reconnectable
        case httpServerError(Int)         // 5xx — reconnectable
        case decodeError(String)          // Format/codec error — NOT reconnectable
        case invalidResponse              // Not HTTP — NOT reconnectable
        case playlistResolutionFailed(String) // M3U/PLS failure — reconnectable (may be DNS)
        case userStopped                  // Explicit stop() — NOT reconnectable
    }

    private(set) var state: StreamState = .idle

    // MARK: - Callbacks (to StreamPlayer)

    var onStateChange: (@MainActor @Sendable (StreamState) -> Void)?
    var onFormatReady: (@MainActor @Sendable (Float64) -> Void)?
    var onMetadata: (@MainActor @Sendable (ICYFramer.ICYMetadata) -> Void)?
    var onTermination: (@MainActor @Sendable (StreamTerminationReason) -> Void)?

    /// Fires when buffered frames reach `resumePrebufferThreshold` after a pause→resume.
    /// One-shot per resume cycle (re-armed by `resetPrebufferTracking`).
    var onPrebufferReady: (@MainActor @Sendable () -> Void)?
    /// Receives analyzer frames for the decoded audio, so the spectrum analyzer
    /// reads a stream the same way it reads a file.
    var spectrumFeed: SpectrumBandFeed?

    // MARK: - Ring Buffer (shared with AudioPlayer's AVAudioSourceNode)

    private(set) var ringBuffer: LockFreeRingBuffer?

    // MARK: - Audio Workgroup

    /// Audio IO workgroup for decode thread priority. Set after bridge activation,
    /// cleared on stop. Passed to DecodeContext for per-block join/leave.
    private var audioWorkgroup: os_workgroup_t?

    /// Set the audio IO workgroup. Called by PlaybackCoordinator after bridge activation.
    /// The workgroup is forwarded to DecodeContext (queue-confined) for per-block join/leave.
    func setAudioWorkgroup(_ workgroup: os_workgroup_t?) {
        audioWorkgroup = workgroup
        let ctx = decodeContext
        nonisolated(unsafe) let wg = workgroup
        decodeQueue.async {
            ctx?.audioWorkgroup = wg
        }
    }

    // MARK: - Decode Context (queue-confined, NOT @MainActor)

    private let decodeQueue = DispatchQueue(label: "com.macamp.stream.decode", qos: .userInitiated)
    private var decodeContext: DecodeContext?

    // MARK: - URLSession

    private var urlSession: URLSession?
    private var dataTask: URLSessionDataTask?
    private var delegateProxy: SessionDelegateProxy?

    // MARK: - HLS

    /// How HLS playlists and segments are fetched. Tests replace it.
    var hlsFetch: HLSSegmentLoader.Fetch = HLSSegmentLoader.fetchWithURLSession

    /// How a playlist URL is fetched to decide what it holds. Tests replace it.
    var playlistFetch: @Sendable (URL) async throws -> (Data, URLResponse) = { url in
        try await URLSession.shared.data(from: url)
    }

    /// True while the running stream is HLS. Such a stream has no connection to suspend, and a
    /// live one cannot resume where it paused, so `StreamPlayer` pauses it by stopping it.
    private(set) var isHLS = false
    private var hlsTask: Task<Void, Never>?

    /// True while the URLSession data task is suspended for backpressure.
    /// Set by `suspendIngestIfNeeded` when the decoder reports a near-full
    /// ring; cleared by `resumeIngestIfDrained` when the main-actor poll
    /// sees the ring drop below `ingestResumeRatio`. Suspending the task
    /// stops URLSession from delivering more bytes, which propagates as
    /// TCP backpressure to the server.
    private var isIngestSuspended: Bool = false

    func suspendIngestIfNeeded() {
        guard !isIngestSuspended, let dataTask, dataTask.state == .running else { return }
        dataTask.suspend()
        isIngestSuspended = true
        AppLog.debug(.audio, "StreamDecodePipeline: ingest suspended (ring near cap)")
    }

    func resumeIngestIfDrained(ringLevel: Int, capacity: Int) {
        guard isIngestSuspended else { return }
        // The matching suspend high-water mark and this resume low-water mark
        // live as constants on DecodeContext (same file, file-private access).
        let resumeMark = Int(Double(capacity) * DecodeContext.ingestResumeRatio)
        guard ringLevel < resumeMark else { return }
        dataTask?.resume()
        isIngestSuspended = false
        AppLog.debug(.audio, "StreamDecodePipeline: ingest resumed (ring drained)")
    }

    // MARK: - Generation Token

    /// Incremented on each start() AND stop(). All callbacks check generation
    /// to reject stale data from previous streams.
    private var generation: UInt64 = 0

    // MARK: - Stream Format (parser-derived, main-actor mirrors)

    /// Channel count from the parser's ASBD `mChannelsPerFrame`. 0 until
    /// the first `onChannelCountAvailable` fires. Cleared in `stopInternal`.
    private(set) var currentChannelCount: Int = 0

    /// Sample rate from the parser's ASBD `mSampleRate`. 0 until the first
    /// `onFormatReady` fires.
    private(set) var currentSampleRate: Float64 = 0

    /// Render-driven bitrate computation. Frame coordinate is the ring
    /// buffer's `writeHead`/`readHead`. Markers are appended on the
    /// main actor as decoded batches land in the ring; `currentBitrate`
    /// reads against the ring's `readHead` so the displayed value tracks
    /// what is *currently being played*, not the bursty decode timing.
    let bitrateTracker = BitrateTracker()

    // MARK: - Prebuffer Tracking

    private var formatReadyFired: Bool = false

    /// Set to true when stop() is called by the user (vs pipeline error/server close).
    /// Checked in handleStreamComplete to classify the termination reason.
    private var userRequestedStop: Bool = false

    // MARK: - Lifecycle

    func start(url: URL, ringBuffer: LockFreeRingBuffer) {
        // Teardown previous (also advances generation)
        stopInternal()

        userRequestedStop = false
        generation &+= 1
        let currentGeneration = generation

        self.ringBuffer = ringBuffer
        ringBuffer.flush()
        formatReadyFired = false

        // Check if URL is a playlist file — resolve to actual stream URL first
        if Self.isPlaylistURL(url) {
            setState(.connecting)
            Task { @MainActor [weak self] in
                guard let self, currentGeneration == self.generation else { return }
                do {
                    let source = try await Self.resolveSource(url, fetch: self.playlistFetch)
                    guard currentGeneration == self.generation else { return }
                    switch source {
                    case .direct(let streamURL):
                        AppLog.info(.audio, "StreamDecodePipeline: Resolved playlist → \(streamURL.absoluteString)")
                        self.startDirectStream(url: streamURL, ringBuffer: ringBuffer, generation: currentGeneration)
                    case .hls(let mediaURL):
                        AppLog.info(.audio, "StreamDecodePipeline: HLS stream → \(mediaURL.absoluteString)")
                        self.startHLSStream(mediaURL: mediaURL, ringBuffer: ringBuffer, generation: currentGeneration)
                    }
                } catch let error as PlaylistResolveError {
                    guard currentGeneration == self.generation else { return }
                    if case .hlsUnsupported(let message) = error {
                        self.setState(.error(message))
                        self.onTermination?(.decodeError(message))
                    } else {
                        let message = "Failed to resolve playlist: \(error.localizedDescription)"
                        self.setState(.error(message))
                        self.onTermination?(.playlistResolutionFailed(message))
                    }
                } catch {
                    guard currentGeneration == self.generation else { return }
                    let message = "Failed to resolve playlist: \(error.localizedDescription)"
                    self.setState(.error(message))
                    self.onTermination?(.playlistResolutionFailed(message))
                }
            }
            return
        }

        startDirectStream(url: url, ringBuffer: ringBuffer, generation: currentGeneration)
    }

    /// The decode chain for one stream. `bounded` is set for HLS, whose feeder waits for room in
    /// the ring instead of relying on a connection to suspend.
    private func makeDecodeContext(
        ringBuffer: LockFreeRingBuffer,
        formatHint: AudioFileTypeID,
        bounded: Bool,
        generation currentGeneration: UInt64
    ) -> DecodeContext {
        let spectrumGeneration = spectrumFeed?.reset() ?? 0
        return DecodeContext(
            decodeQueue: decodeQueue,
            ringBuffer: ringBuffer,
            spectrumFeed: spectrumFeed,
            spectrumGeneration: spectrumGeneration,
            formatHint: formatHint,
            bounded: bounded,
            generation: currentGeneration,
            onFormatReady: { [weak self] sampleRate, gen in
                Task { @MainActor [weak self] in
                    guard let self, gen == self.generation, !self.formatReadyFired else { return }
                    self.formatReadyFired = true
                    self.currentSampleRate = sampleRate
                    self.setState(.playing)
                    self.onFormatReady?(sampleRate)
                    AppLog.info(.audio, "StreamDecodePipeline: Format ready — \(sampleRate)Hz")
                }
            },
            onMetadata: { [weak self] metadata, gen in
                Task { @MainActor [weak self] in
                    guard let self, gen == self.generation else { return }
                    self.onMetadata?(metadata)
                }
            },
            onError: { [weak self] message, gen in
                Task { @MainActor [weak self] in
                    guard let self, gen == self.generation else { return }
                    self.stopInternal()
                    self.setState(.error(message))
                    self.onTermination?(.decodeError(message))
                    AppLog.error(.audio, "StreamDecodePipeline: Decode error — \(message)")
                }
            },
            onPrebufferReady: { [weak self] gen in
                Task { @MainActor [weak self] in
                    guard let self, gen == self.generation else { return }
                    self.onPrebufferReady?()
                }
            },
            onBackpressureRequest: { [weak self] gen in
                Task { @MainActor [weak self] in
                    guard let self, gen == self.generation else { return }
                    self.suspendIngestIfNeeded()
                }
            },
            onChannelCountAvailable: { [weak self] channels, gen in
                Task { @MainActor [weak self] in
                    guard let self, gen == self.generation else { return }
                    self.currentChannelCount = channels
                }
            },
            onBitrateMarker: { [weak self] framePosition, bytes, sampleRate, gen in
                Task { @MainActor [weak self] in
                    guard let self, gen == self.generation else { return }
                    // Defensively keep `currentSampleRate` in sync. In
                    // practice `onFormatReady` always lands first, but
                    // Swift concurrency doesn't formally guarantee
                    // same-actor FIFO ordering across separate Tasks, and
                    // the streamed sampleRate here is authoritative.
                    if self.currentSampleRate == 0 {
                        self.currentSampleRate = sampleRate
                    }
                    self.bitrateTracker.appendMarker(
                        framePosition: framePosition,
                        cumulativeCompressedBytes: bytes
                    )
                    self.pruneBitrateMarkers(sampleRate: sampleRate)
                }
            }
        )
    }

    /// Start streaming from a direct audio URL (not a playlist).
    private func startDirectStream(url: URL, ringBuffer: LockFreeRingBuffer, generation currentGeneration: UInt64) {
        let formatHint = Self.formatHint(for: url)
        let context = makeDecodeContext(
            ringBuffer: ringBuffer,
            formatHint: formatHint,
            bounded: false,
            generation: currentGeneration
        )
        decodeContext = context

        // Create URLSession with delegate proxy
        // Proxy callbacks are set once before URLSession starts, then immutable.
        let proxy = SessionDelegateProxy(
            onResponse: { [weak self, weak context] response in
                // Configure framer DIRECTLY on decode queue — NOT via MainActor hop.
                // URLSession calls didReceive(data:) right after didReceive(response:).
                // If we hop to MainActor first, data arrives on the decode queue BEFORE
                // the framer is configured → metadata bytes injected into audio → warping.
                // By dispatching framer config to the decode queue here, ordering with
                // data delivery is guaranteed by the serial queue.
                if let httpResponse = response as? HTTPURLResponse {
                    let metaInt = StreamDecodePipeline.extractICYMetaInt(from: httpResponse.allHeaderFields) ?? 0
                    context?.configureFramer(metaInterval: metaInt)
                    let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
                    context?.applyContentTypeHint(StreamDecodePipeline.formatHint(forContentType: contentType))
                }
                // State updates still go to MainActor
                Task { @MainActor [weak self] in
                    self?.handleHTTPResponse(response, generation: currentGeneration)
                }
            },
            onData: { [weak context] data in
                context?.handleIncomingData(data)
            },
            onComplete: { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.handleStreamComplete(error: error, generation: currentGeneration)
                }
            }
        )
        delegateProxy = proxy

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 0
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.qualityOfService = .userInitiated
        urlSession = URLSession(configuration: sessionConfig, delegate: proxy, delegateQueue: operationQueue)

        var request = URLRequest(url: url)
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        dataTask = urlSession?.dataTask(with: request)
        setState(.connecting)
        dataTask?.resume()

        AppLog.info(.audio, "StreamDecodePipeline: Starting — \(url.absoluteString)")
    }

    // MARK: - HLS stream

    /// Bytes handed to the decoder at a time. Each chunk is decoded and written before the next
    /// is sent, which bounds how far the ring can overshoot its fill mark.
    private nonisolated static let hlsChunkBytes = 4096

    private enum HLSOutcome: Sendable {
        case ended
        case failed(any Error)
        case cancelled
    }

    /// Stream a live HLS playlist: fetch its segments, unwrap their audio, and feed it to the
    /// same parser, decoder and ring buffer an ICY stream uses.
    private func startHLSStream(mediaURL: URL, ringBuffer: LockFreeRingBuffer, generation currentGeneration: UInt64) {
        isHLS = true
        let context = makeDecodeContext(
            ringBuffer: ringBuffer,
            formatHint: kAudioFileAAC_ADTSType,
            bounded: true,
            generation: currentGeneration
        )
        decodeContext = context
        setState(.connecting)

        let loader = HLSSegmentLoader(playlistURL: mediaURL, fetch: hlsFetch)
        hlsTask = Task { [weak self] in
            let outcome = await Self.runHLS(loader: loader, context: context, ringBuffer: ringBuffer)
            await self?.finishHLS(outcome, generation: currentGeneration)
        }
        AppLog.info(.audio, "StreamDecodePipeline: Starting HLS — \(mediaURL.absoluteString)")
    }

    /// Pull segments and feed their audio to `context`, waiting whenever the ring is half full
    /// so the ring never overflows and nothing is downloaded that cannot yet be played.
    private nonisolated static func runHLS(
        loader: HLSSegmentLoader,
        context: DecodeContext,
        ringBuffer: LockFreeRingBuffer
    ) async -> HLSOutcome {
        let demuxer = TransportStreamAudioDemuxer()
        let resumeMark = Int(Double(ringBuffer.capacity) * DecodeContext.ingestResumeRatio)

        func waitForRoom() async throws {
            while ringBuffer.availableFrames >= resumeMark {
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        do {
            while let segment = try await loader.next() {
                if segment.followsDiscontinuity { demuxer.markDiscontinuity() }
                for event in try demuxer.demux(segment: segment.data) {
                    switch event {
                    case .discontinuity:
                        await context.discontinuity()
                    case .audio(let audio):
                        var offset = audio.startIndex
                        while offset < audio.endIndex {
                            try await waitForRoom()
                            let end = min(offset + hlsChunkBytes, audio.endIndex)
                            var yielded = await context.feed(Data(audio[offset..<end]))
                            while yielded {
                                try await waitForRoom()
                                yielded = await context.drain()
                            }
                            offset = end
                        }
                    }
                }
            }
            return .ended
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error)
        }
    }

    private func finishHLS(_ outcome: HLSOutcome, generation currentGeneration: UInt64) {
        guard currentGeneration == generation else { return }
        switch outcome {
        case .cancelled:
            return
        case .ended:
            // The playlist ended, which for a live stream is the server closing it.
            handleStreamComplete(error: nil, generation: currentGeneration)
        case .failed(let error):
            let (reason, message) = Self.terminationReason(forHLS: error)
            stopInternal()
            setState(.error(message))
            onTermination?(reason)
            AppLog.error(.audio, "StreamDecodePipeline: HLS failed — \(message)")
        }
    }

    private static func terminationReason(forHLS error: any Error) -> (StreamTerminationReason, String) {
        switch error {
        case let loadError as HLSSegmentLoader.LoadError:
            switch loadError {
            case .http(let status):
                let message = "HTTP \(status)"
                // 429 is reconnectable like 5xx, as for a direct stream.
                return status == 429 || status >= 500 ? (.httpServerError(status), message) : (.httpClientError(status), message)
            case .network(let message, let code):
                return (.networkError(message, code), message)
            case .stalled:
                let message = "HLS playlist stopped updating"
                return (.networkError(message, NSURLErrorTimedOut), message)
            case .onDemand:
                let message = "On-demand HLS streams are not supported"
                return (.decodeError(message), message)
            case .invalidPlaylist(let message):
                // A garbled playlist may be a passing fault at the origin, so a retry is worthwhile.
                return (.playlistResolutionFailed(message), message)
            case .unsupported(let message):
                return (.decodeError(message), message)
            case .overlappingPull:
                let message = "HLS loader misuse"
                return (.decodeError(message), message)
            }
        case is TransportStreamAudioDemuxer.DemuxError:
            let message = "Unsupported HLS audio codec"
            return (.decodeError(message), message)
        default:
            return (.networkError(error.localizedDescription, (error as NSError).code), error.localizedDescription)
        }
    }

    /// Suspends the URLSession data task, then awaits a decode-queue barrier that raises
    /// `isPausedByUser`, clears the decoder, and flushes the ring (see `setPausedByUser`).
    /// Returns only after the producer is fully quiesced.
    func pauseByUser() async {
        guard case .playing = state else { return }
        if Task.isCancelled { return }
        if isIngestSuspended {
            // The data task is already suspended for backpressure. URLSession
            // suspends are reference-counted, so a second suspend here would
            // require a matching second resume to actually deliver data again.
            // Hand the suspension over to user-pause and clear our flag.
            isIngestSuspended = false
        } else {
            dataTask?.suspend()
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            guard let ctx = decodeContext else { cont.resume(); return }
            ctx.setPausedByUser(true) { cont.resume() }
        }
        if Task.isCancelled { return }
        // Re-check: a concurrent stop() could have torn the pipeline down during the await.
        guard case .playing = state else { return }
        setState(.paused)
    }

    /// Resets prebuffer tracking BEFORE clearing the pause flag so first bytes count toward
    /// the resume threshold. StreamPlayer keeps user-visible state suppressed until
    /// `onPrebufferReady`; transport state and user state diverge by design.
    func resumeByUser() async {
        guard case .paused = state else { return }
        if Task.isCancelled { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            guard let ctx = decodeContext else { cont.resume(); return }
            ctx.resetPrebufferTracking { cont.resume() }
        }
        if Task.isCancelled { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            guard let ctx = decodeContext else { cont.resume(); return }
            ctx.setPausedByUser(false) { cont.resume() }
        }
        if Task.isCancelled { return }
        guard case .paused = state else { return }
        dataTask?.resume()
        setState(.playing)
    }

    func stop() {
        userRequestedStop = true
        stopInternal()
        setState(.idle)
        onTermination?(.userStopped)
    }

    isolated deinit {
        hlsTask?.cancel()
        dataTask?.cancel()
        urlSession?.invalidateAndCancel()
        decodeContext?.shutdown()
    }

    // MARK: - Internal

    private func stopInternal() {
        // Advance generation FIRST — stale callbacks will be rejected
        generation &+= 1

        dataTask?.cancel()
        dataTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        delegateProxy = nil
        hlsTask?.cancel()
        hlsTask = nil
        isHLS = false
        decodeContext?.shutdown()
        decodeContext = nil
        ringBuffer = nil
        audioWorkgroup = nil
        formatReadyFired = false
        isIngestSuspended = false
        currentChannelCount = 0
        currentSampleRate = 0
        bitrateTracker.reset()
    }

    /// Trim the tracker so its working set stays bounded to roughly one
    /// playback window. Called from the marker append callback — the
    /// ring's read head is the basis for "the past" from the listener's
    /// perspective. `sampleRate` is passed in (rather than read from
    /// `currentSampleRate`) so pruning doesn't depend on the format-ready
    /// Task having already landed on the main actor.
    private func pruneBitrateMarkers(sampleRate: Float64) {
        guard let ringBuffer, sampleRate > 0 else { return }
        let readPos = ringBuffer.readHeadFrames
        let windowFrames = UInt64(sampleRate * BitrateTracker.windowSeconds)
        let windowStart = readPos > windowFrames ? readPos &- windowFrames : 0
        bitrateTracker.pruneBelow(framePosition: windowStart)
    }

    private func setState(_ newState: StreamState) {
        state = newState
        onStateChange?(newState)
    }

    // MARK: - HTTP Response (MainActor)

    private func handleHTTPResponse(_ response: URLResponse, generation: UInt64) {
        guard generation == self.generation else { return }

        guard let httpResponse = response as? HTTPURLResponse else {
            stopInternal()
            setState(.error("Invalid HTTP response"))
            onTermination?(.invalidResponse)
            return
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let status = httpResponse.statusCode
            stopInternal()
            setState(.error("HTTP \(status)"))
            if status == 429 {
                onTermination?(.httpServerError(status))  // 429 Too Many Requests — reconnectable with backoff
            } else if (400...499).contains(status) {
                onTermination?(.httpClientError(status))
            } else {
                onTermination?(.httpServerError(status))
            }
            return
        }

        // NOTE: configureFramer is called from the onResponse callback (delegate queue)
        // BEFORE data delivery begins. Do NOT call it again here — the MainActor hop
        // means this runs AFTER data has already been processed, which would reset the
        // framer's byte counter and corrupt ICY metadata boundary alignment.
        setState(.buffering)
    }

    /// Case-insensitive lookup for icy-metaint header.
    /// nonisolated: pure function, safe to call from any context (URLSession delegate queue).
    private nonisolated static func extractICYMetaInt(from headers: [AnyHashable: Any]) -> Int? {
        for (key, value) in headers {
            if let keyStr = key as? String,
               keyStr.caseInsensitiveCompare("icy-metaint") == .orderedSame,
               let valueStr = value as? String,
               let parsed = Int(valueStr) {
                return parsed
            }
        }
        return nil
    }

    // MARK: - Stream Completion (MainActor)

    private func handleStreamComplete(error: Error?, generation: UInt64) {
        guard generation == self.generation else { return }

        // If user requested stop, the cancellation is expected — don't fire termination again
        // (stop() already fired .userStopped)
        if userRequestedStop {
            return
        }

        stopInternal()

        if let error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                // Cancelled but not by user — likely generation advance from a new start()
                return
            }

            let message = "Stream error: \(error.localizedDescription)"
            let code = (error as NSError).code
            setState(.error(message))
            onTermination?(.networkError(message, code))
            AppLog.error(.audio, "StreamDecodePipeline: \(error.localizedDescription)")
        } else {
            // Server closed connection (no error, not user-initiated)
            setState(.idle)
            onTermination?(.serverClosed)
            AppLog.info(.audio, "StreamDecodePipeline: Stream ended (server closed)")
        }
    }

    // MARK: - Playlist Resolution (M3U, PLS)

    /// Check if a URL points to a playlist file rather than a direct audio stream.
    private static func isPlaylistURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["m3u", "m3u8", "pls"].contains(ext)
    }

    /// Download and parse a playlist file to extract the first stream URL.
    /// Supports M3U/M3U8 and PLS formats.
    private enum ResolvedSource {
        case direct(URL)
        case hls(URL)
    }

    private static func resolveSource(
        _ url: URL,
        fetch: @Sendable (URL) async throws -> (Data, URLResponse)
    ) async throws -> ResolvedSource {
        let (data, response) = try await fetch(url)

        // Check Content-Type for format hint
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""

        guard let content = String(data: data, encoding: .utf8) else {
            throw PlaylistResolveError.encodingError
        }

        if HLSPlaylist.isHLS(content) {
            return try hlsSource(content, playlistURL: response.url ?? url)
        }

        let ext = url.pathExtension.lowercased()

        // Try PLS first if extension or content-type suggests it
        if ext == "pls" || contentType.contains("scpls") {
            if let streamURL = parsePLS(content: content) {
                return .direct(streamURL)
            }
        }

        // Try M3U parsing (works for both .m3u and .m3u8)
        // Pass relativeTo: url so relative entries resolve against the playlist URL
        if let parsed = try? M3UParser.parse(content: content, relativeTo: url),
           let firstStream = parsed.entries.first(where: { !$0.url.isFileURL }) {
            return .direct(firstStream.url)
        }

        // Fallback: try PLS even if extension didn't match
        if let streamURL = parsePLS(content: content) {
            return .direct(streamURL)
        }

        throw PlaylistResolveError.noStreamFound
    }

    /// The media playlist to stream from an HLS playlist: the playlist itself, or for a
    /// master playlist its audio-only variant with the least bandwidth.
    private static func hlsSource(_ content: String, playlistURL: URL) throws -> ResolvedSource {
        let playlist: HLSPlaylist
        do {
            playlist = try HLSPlaylist.parse(content, relativeTo: playlistURL)
        } catch HLSPlaylist.ParseError.unsupportedEncryption {
            throw PlaylistResolveError.hlsUnsupported("Encrypted HLS streams are not supported")
        } catch HLSPlaylist.ParseError.unsupportedInitSegment {
            throw PlaylistResolveError.hlsUnsupported("HLS streams with initialization segments are not supported")
        } catch HLSPlaylist.ParseError.unsupportedByteRange {
            throw PlaylistResolveError.hlsUnsupported("HLS streams with byte ranges are not supported")
        } catch {
            // A malformed playlist may be a passing fault, so unlike an unsupported one it is retried.
            throw PlaylistResolveError.malformedHLS
        }

        switch playlist {
        case .media:
            return .hls(playlistURL)
        case .master(let master):
            guard let variant = master.lowestAudioOnlyVariant else {
                throw PlaylistResolveError.hlsUnsupported("This HLS stream has no audio-only variant")
            }
            return .hls(variant.url)
        }
    }

    /// Parse a PLS playlist file to extract the first stream URL.
    /// PLS format: `File1=http://stream.url/path`
    private static func parsePLS(content: String) -> URL? {
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Match FileN= lines (case-insensitive)
            if trimmed.lowercased().hasPrefix("file") && trimmed.contains("=") {
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let urlStr = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    if let url = URL(string: urlStr),
                       urlStr.lowercased().hasPrefix("http") {
                        return url
                    }
                }
            }
        }
        return nil
    }

    private enum PlaylistResolveError: LocalizedError {
        case encodingError
        case noStreamFound
        /// An HLS playlist this player cannot play. Retrying will not help.
        case hlsUnsupported(String)
        /// A playlist that looks like HLS but could not be read.
        case malformedHLS

        var errorDescription: String? {
            switch self {
            case .encodingError: return "Unable to read playlist file"
            case .hlsUnsupported(let message): return message
            case .malformedHLS: return "Unreadable HLS playlist"
            case .noStreamFound: return "No stream URL found in playlist"
            }
        }
    }

    // MARK: - Format Hint

    private static func formatHint(for url: URL) -> AudioFileTypeID {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mp3": return kAudioFileMP3Type
        case "aac", "aacp": return kAudioFileAAC_ADTSType
        default: break
        }
        let path = url.path.lowercased()
        if path.contains("mp3") || path.contains("mpeg") { return kAudioFileMP3Type }
        if path.contains("aac") { return kAudioFileAAC_ADTSType }
        return 0
    }

    nonisolated static func formatHint(forContentType contentType: String) -> AudioFileTypeID {
        let mime = contentType.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        switch mime {
        case "audio/mpeg", "audio/mp3": return kAudioFileMP3Type
        case "audio/aac", "audio/aacp", "audio/x-aac": return kAudioFileAAC_ADTSType
        default: return 0
        }
    }

    #if DEBUG
    // MARK: - Test Seams (DEBUG only)

    /// Test-only injection of a termination event without going through URLSession.
    /// Routes through `onTermination` so StreamPlayer.handleTermination runs end-to-end.
    internal func injectTerminationForTesting(_ reason: StreamTerminationReason) {
        onTermination?(reason)
    }

    /// Test-only: snapshot of whether `DecodeContext.isPausedByUser` is set.
    /// Hops onto the decode queue with a sync barrier; safe because tests run on the main queue.
    internal func isPausedByUserForTesting() -> Bool {
        decodeContext?.isPausedByUserSnapshotForTesting() ?? false
    }

    /// Test-only: snapshot of `decoder.hasQueuedPackets` via the decode-queue barrier.
    internal func decoderHasQueuedPacketsForTesting() -> Bool {
        decodeContext?.decoderHasQueuedPacketsForTesting() ?? false
    }

    /// Test-only: ring buffer telemetry (relaxed loads — safe to call from any thread).
    internal func ringBufferAvailableFramesForTesting() -> Int {
        decodeContext?.ringBufferAvailableFramesForTesting() ?? 0
    }

    /// Test-only: drive `pipeline.state` directly to exercise StreamPlayer code paths
    /// (e.g. `resume()` while `.playing`) without spinning up a real URLSession.
    internal func setStateForTesting(_ state: StreamState) {
        setState(state)
    }
    #endif

}

// MARK: - DecodeContext (queue-confined, NOT @MainActor)

/// Owns all decode-queue-confined state. Accessed ONLY from the decode serial queue.
/// Separated from the @MainActor pipeline to avoid isolation conflicts.
///
/// @unchecked Sendable: All mutable state is confined to the decode serial queue.
/// Debug assertions (dispatchPrecondition) verify confinement on internal methods.
/// This is the same pattern as VisualizerScratchBuffers in VisualizerPipeline.swift.
private final class DecodeContext: @unchecked Sendable {
    private let decodeQueue: DispatchQueue
    private let ringBuffer: LockFreeRingBuffer
    private let spectrumFeed: SpectrumBandFeed?
    private let spectrumGeneration: UInt64
    private let spectrumFeeder = SpectrumBandFeeder()
    private let generation: UInt64

    /// HLS contexts hold back decoding when the ring fills (see `decodeQueued`) and end the
    /// stream if its audio format changes. ICY contexts keep decoding everything they are given.
    private let bounded: Bool

    private var framer = ICYFramer()
    private var parser: AudioFileStreamParser?
    private var establishedFormat: AudioStreamBasicDescription?
    /// Set on the decode queue the moment the stream is rejected, so nothing more is decoded or
    /// written while the main-actor shutdown it requested is still on its way.
    private var failed = false
    private var formatHint: AudioFileTypeID = 0
    private var decoder: AudioConverterDecoder?
    private var magicCookie: Data?
    private var prebufferedFrames: Int = 0
    private var formatReadyFired: Bool = false
    private var detectedSampleRate: Float64 = 0
    private var isShutdown: Bool = false

    /// While true, `handleIncomingData` and `handlePackets` short-circuit. Set on the decode queue.
    private var isPausedByUser: Bool = false

    /// One-shot per resume cycle. Starts `true` (initial stream uses `formatReadyFired` instead);
    /// `resetPrebufferTracking` flips it to `false` at resume time.
    private var prebufferReadyFiredOnResume: Bool = true

    /// Audio IO workgroup — set after bridge activation, used for per-block join/leave.
    /// Queue-confined: only accessed from decodeQueue.
    var audioWorkgroup: os_workgroup_t?

    /// Seconds of decoded audio required before the first
    /// `onFormatReady` fires (initial startup latency). Matches VLC's
    /// `--network-caching` default — a one-second startup feels prompt
    /// while still giving the network a tick to settle.
    static let initialPrebufferSeconds: Double = 1.0
    /// Seconds of decoded audio required before `onPrebufferReady` fires
    /// after a user-initiated pause→resume.
    static let resumePrebufferSeconds: Double = 1.0
    /// Seconds of decoded audio required before the render thread is
    /// allowed to resume reading after a mid-stream underrun. Matches
    /// MPV's `--cache-pause-wait` default.
    static let rebufferRefillSeconds: Double = 1.0
    /// Buffer fill ratio at which we suspend the URLSession data task.
    /// 0.9 = nine-tenths full. Decoder writes can climb a few more
    /// percent of capacity before the suspension takes effect (it's
    /// applied via a main-actor hop), so the high-water mark is left
    /// with some headroom under the cap.
    static let ingestSuspendRatio: Double = 0.9
    /// Buffer fill ratio at which we resume the URLSession data task.
    /// Hysteresis: the gap to `ingestSuspendRatio` prevents
    /// suspend/resume thrashing when the buffer hovers near the cap.
    static let ingestResumeRatio: Double = 0.5

    /// Thresholds in frames at the stream's detected sample rate.
    /// `detectedSampleRate` is set in `formatChanged(...)` before any
    /// packet is decoded, so by the time `prebufferedFrames` advances
    /// the rate is always non-zero.
    private var prebufferThreshold: Int {
        Int((detectedSampleRate > 0 ? detectedSampleRate : 44100) * Self.initialPrebufferSeconds)
    }
    private var resumePrebufferThreshold: Int {
        Int((detectedSampleRate > 0 ? detectedSampleRate : 44100) * Self.resumePrebufferSeconds)
    }
    private var rebufferRefillThreshold: Int {
        Int((detectedSampleRate > 0 ? detectedSampleRate : 44100) * Self.rebufferRefillSeconds)
    }

    private let onFormatReady: @Sendable (Float64, UInt64) -> Void
    private let onMetadata: @Sendable (ICYFramer.ICYMetadata, UInt64) -> Void
    private let onError: @Sendable (String, UInt64) -> Void
    private let onPrebufferReady: @Sendable (UInt64) -> Void
    /// Fired from the decode queue when the ring buffer crosses the
    /// ingest-suspend high-water mark. Pipeline suspends the URLSession
    /// data task in response, which propagates as TCP backpressure to the
    /// server. Resumption is driven from the main-actor poll on
    /// StreamPlayer's elapsed timer.
    private let onBackpressureRequest: @Sendable (UInt64) -> Void
    /// Fired with the stream's channel count from the parser's ASBD
    /// (`mChannelsPerFrame`). Mono streams report 1, stereo 2. Fires once
    /// per stream, alongside the first `onFormatReady`.
    private let onChannelCountAvailable: @Sendable (Int, UInt64) -> Void
    /// Fired after each decode batch has been written to the ring buffer.
    /// Carries the ring's `writeHead` after the batch, the decoder's
    /// cumulative compressed-bytes total, and the stream's sample rate
    /// (so the main-actor handler can prune without depending on the
    /// separately-set `currentSampleRate` having already landed). The
    /// pipeline accumulates these into the bitrate marker queue and
    /// computes the displayed bitrate from the markers straddling the
    /// ring's `readHead`, so the value tracks what is *currently being
    /// played* rather than what was just decoded.
    private let onBitrateMarker: @Sendable (UInt64, UInt64, Float64, UInt64) -> Void

    init(
        decodeQueue: DispatchQueue,
        ringBuffer: LockFreeRingBuffer,
        spectrumFeed: SpectrumBandFeed?,
        spectrumGeneration: UInt64,
        formatHint: AudioFileTypeID,
        bounded: Bool,
        generation: UInt64,
        onFormatReady: @escaping @Sendable (Float64, UInt64) -> Void,
        onMetadata: @escaping @Sendable (ICYFramer.ICYMetadata, UInt64) -> Void,
        onError: @escaping @Sendable (String, UInt64) -> Void,
        onPrebufferReady: @escaping @Sendable (UInt64) -> Void,
        onBackpressureRequest: @escaping @Sendable (UInt64) -> Void,
        onChannelCountAvailable: @escaping @Sendable (Int, UInt64) -> Void,
        onBitrateMarker: @escaping @Sendable (UInt64, UInt64, Float64, UInt64) -> Void
    ) {
        self.decodeQueue = decodeQueue
        self.ringBuffer = ringBuffer
        self.spectrumFeed = spectrumFeed
        self.spectrumGeneration = spectrumGeneration
        self.bounded = bounded
        self.generation = generation
        self.onFormatReady = onFormatReady
        self.onMetadata = onMetadata
        self.onError = onError
        self.onPrebufferReady = onPrebufferReady
        self.onBackpressureRequest = onBackpressureRequest
        self.onChannelCountAvailable = onChannelCountAvailable
        self.onBitrateMarker = onBitrateMarker

        self.formatHint = formatHint

        decodeQueue.async { [self] in
            installParser(formatHint: formatHint)
        }
    }

    private func installParser(formatHint: AudioFileTypeID) {
        let parser = AudioFileStreamParser(formatHint: formatHint)
        parser.confinementQueue = decodeQueue

        parser.onFormatAvailable = { [weak self] asbd in
            self?.handleFormatAvailable(asbd)
        }
        parser.onMagicCookie = { [weak self] cookie in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(self.decodeQueue))
            self.magicCookie = cookie
        }
        parser.onError = { [weak self] message in
            guard let self else { return }
            self.onError(message, self.generation)
        }
        parser.onPackets = { [weak self] data, descriptions in
            self?.handlePackets(data: data, descriptions: descriptions)
        }

        self.parser = parser

        // Check for deferred init error (AudioFileStreamOpen failed before callbacks were wired)
        if let error = parser.initError {
            self.onError(error, self.generation)
        }
    }

    /// Replace the parser with one using the response's Content-Type hint when the URL gave none.
    /// Dispatched to decode queue, so it runs before the first body bytes are parsed.
    func applyContentTypeHint(_ hint: AudioFileTypeID) {
        decodeQueue.async { [self] in
            guard !isShutdown, formatHint == 0, hint != 0 else { return }
            formatHint = hint
            parser?.close()
            installParser(formatHint: hint)
        }
    }

    /// Configure the ICY framer with metaint value.
    /// Dispatched to decode queue — preserves ordering with data delivery.
    func configureFramer(metaInterval: Int) {
        decodeQueue.async { [self] in
            guard !isShutdown else { return }
            framer.configure(metaInterval: metaInterval)
        }
    }

    /// Process incoming HTTP data. Dispatched to decode queue.
    /// Joins audio workgroup for the duration of decode work (per-block join/leave).
    func handleIncomingData(_ data: Data) {
        decodeQueue.async { [self] in
            // `isPausedByUser` is raised in the same async block as the flush, so late
            // URLSession callbacks delivered after pause are dropped here.
            guard !isShutdown, !isPausedByUser else { return }

            let token = joinWorkgroupIfAvailable()
            defer {
                if let t = token { leaveWorkgroup(token: t) }
            }

            let chunks = framer.consume(data)

            for chunk in chunks {
                switch chunk {
                case .audio(let audioData):
                    parser?.parse(audioData)
                case .metadata(let metadata):
                    onMetadata(metadata, generation)
                }
            }
        }
    }

    // MARK: - HLS feeding

    /// Parse ADTS bytes from an HLS segment. Each call completes only once the bytes
    /// have been parsed and every packet that fits has been decoded and written, so the
    /// caller never has more than one chunk in flight.
    /// - Returns: true while decoded packets remain queued because the ring is too full;
    ///   the caller waits for room and calls `drain()`.
    func feed(_ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            decodeQueue.async { [self] in
                guard !isShutdown, !isPausedByUser else {
                    continuation.resume(returning: false)
                    return
                }
                let token = joinWorkgroupIfAvailable()
                defer {
                    if let t = token { leaveWorkgroup(token: t) }
                }
                parser?.parse(data)
                continuation.resume(returning: yielded)
            }
        }
    }

    /// Decode the packets a previous `feed` left queued. Same result as `feed`.
    func drain() async -> Bool {
        await withCheckedContinuation { continuation in
            decodeQueue.async { [self] in
                guard !isShutdown, !isPausedByUser else {
                    continuation.resume(returning: false)
                    return
                }
                let token = joinWorkgroupIfAvailable()
                defer {
                    if let t = token { leaveWorkgroup(token: t) }
                }
                decodeQueued()
                continuation.resume(returning: yielded)
            }
        }
    }

    /// The audio after this point does not continue the audio before it. Call only
    /// once `feed` and `drain` have returned false, so no earlier audio is still queued.
    ///
    /// The converter and the spectrum analysis start over, and the parser is opened afresh so
    /// it detects the new audio's format again and `handleFormatAvailable` can compare it.
    func discontinuity() async {
        await withCheckedContinuation { continuation in
            decodeQueue.async { [self] in
                if !isShutdown {
                    decoder?.clearQueue()
                    spectrumFeeder.reset()
                    parser?.close()
                    installParser(formatHint: formatHint)
                }
                continuation.resume()
            }
        }
    }

    /// On `paused=true`, in this exact order: gate up, drop in-flight packets, flush the
    /// ring. The serial queue guarantees no other handler runs between steps.
    func setPausedByUser(_ paused: Bool, completion: @escaping @Sendable () -> Void) {
        decodeQueue.async { [self] in
            guard !isShutdown else { completion(); return }
            isPausedByUser = paused
            if paused {
                decoder?.clearQueue()
                ringBuffer.flush(newGeneration: false)
            }
            completion()
        }
    }

    /// Caller must invoke this BEFORE clearing `isPausedByUser` so first post-resume bytes
    /// count toward `resumePrebufferThreshold`, not the stale pre-pause counter.
    func resetPrebufferTracking(completion: @escaping @Sendable () -> Void) {
        decodeQueue.async { [self] in
            guard !isShutdown else { completion(); return }
            prebufferedFrames = 0
            prebufferReadyFiredOnResume = false
            completion()
        }
    }

    /// Shutdown the decode chain. C API ordering: converter before parser.
    /// After shutdown, all subsequent decode-queue work is rejected via isShutdown flag.
    func shutdown() {
        decodeQueue.async { [self] in
            guard !isShutdown else { return }
            isShutdown = true
            decoder?.dispose()
            decoder = nil
            parser?.close()
            parser = nil
        }
    }

    // MARK: - Workgroup Join/Leave (decode queue only)

    /// Join the audio IO workgroup for the current block. Returns opaque token for leave.
    /// Called at the start of each decode dispatch block; left at the end via defer.
    /// Per-block join/leave is required because GCD serial queues reuse threads.
    /// Uses ObjC shim because os_workgroup C APIs are not available in Swift.
    private func joinWorkgroupIfAvailable() -> UnsafeMutableRawPointer? {
        guard let wg = audioWorkgroup else { return nil }
        return AudioWorkgroupJoin(wg)
    }

    /// Leave the audio IO workgroup. Token must be the value from joinWorkgroupIfAvailable.
    private func leaveWorkgroup(token: UnsafeMutableRawPointer) {
        guard let wg = audioWorkgroup else { return }
        AudioWorkgroupLeave(wg, token)
    }

    // MARK: - Internal (decode queue only)

    private func handleFormatAvailable(_ asbd: AudioStreamBasicDescription) {
        dispatchPrecondition(condition: .onQueue(decodeQueue))
        guard !isShutdown else { return }
        if decoder != nil {
            // An HLS stream cannot change format mid-stream: the ring buffer, source node and
            // decoder are all built for the first one.
            if bounded, let established = establishedFormat, !Self.sameFormat(established, asbd) {
                failed = true
                onError("HLS audio format changed", generation)
            }
            return
        }
        establishedFormat = asbd

        let newDecoder = AudioConverterDecoder(inputFormat: asbd, magicCookie: magicCookie)

        // Surface converter creation failure instead of silently hanging in "buffering"
        guard newDecoder.converter != nil else {
            onError("AudioConverter creation failed for format \(asbd.mSampleRate)Hz", generation)
            return
        }

        newDecoder.confinementQueue = decodeQueue
        decoder = newDecoder

        // Report the DECODER's output rate (not stream rate) so the source node format matches
        detectedSampleRate = newDecoder.sampleRate

        // Surface the stream's channel count from the ASBD — the source node
        // is always rendered stereo, but the indicator UI shows the source's
        // actual layout (mono vs stereo) per the parser.
        let channels = Int(asbd.mChannelsPerFrame)
        if channels > 0 {
            onChannelCountAvailable(channels, generation)
        }

        AppLog.info(.audio, "DecodeContext: Decoder created — \(asbd.mSampleRate)Hz → \(newDecoder.sampleRate)Hz")
    }

    private static func sameFormat(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mFormatID == b.mFormatID && a.mSampleRate == b.mSampleRate && a.mChannelsPerFrame == b.mChannelsPerFrame
    }

    private func handlePackets(data: Data, descriptions: [AudioStreamPacketDescription]) {
        dispatchPrecondition(condition: .onQueue(decodeQueue))
        guard !isShutdown, !failed, let decoder else { return }

        // Split batched packets into individual entries.
        // AudioFileStream delivers multiple packets in one callback (concatenated data
        // with per-packet descriptions). If we enqueue the whole batch as one entry,
        // the AudioConverter's input callback provides ALL packets at once. When the
        // output buffer fills mid-batch, the remaining packets are LOST because
        // advanceToNextPacket() moves to the next queue entry (which doesn't exist).
        // Splitting ensures each advanceToNextPacket() gets exactly one packet.
        if descriptions.isEmpty {
            // CBR format — no descriptions, enqueue as-is
            decoder.enqueue(data: data, descriptions: [])
        } else {
            for desc in descriptions {
                let offset = Int(desc.mStartOffset)
                let size = Int(desc.mDataByteSize)
                guard offset >= 0, size > 0, offset + size <= data.count else { continue }
                let packetData = data[offset..<(offset + size)]
                let singleDesc = AudioStreamPacketDescription(
                    mStartOffset: 0,  // Offset is 0 within the individual packet
                    mVariableFramesInPacket: desc.mVariableFramesInPacket,
                    mDataByteSize: desc.mDataByteSize
                )
                decoder.enqueue(data: Data(packetData), descriptions: [singleDesc])
            }
        }

        decodeQueued()
    }

    /// True when the last `decodeQueued` stopped with packets still queued because the
    /// ring was too full.
    private var yielded = false

    /// Decode and write every queued packet. A bounded context stops at the ingest-suspend
    /// high-water mark and leaves the rest queued: a few kilobytes of near-silent AAC
    /// can expand into more audio than the ring has room for.
    private func decodeQueued() {
        dispatchPrecondition(condition: .onQueue(decodeQueue))
        yielded = false
        guard !isShutdown, !failed, let decoder else { return }
        let suspendMark = Int(Double(ringBuffer.capacity) * Self.ingestSuspendRatio)

        while decoder.hasQueuedPackets {
            guard !isShutdown, !isPausedByUser else { break }
            if bounded && ringBuffer.availableFrames >= suspendMark {
                yielded = true
                break
            }
            guard let (pcmBuffer, frameCount) = decoder.decode() else { break }

            let chunkStartFrame = ringBuffer.writeHeadFrames
            let framesWritten = ringBuffer.write(from: pcmBuffer, frameCount: frameCount)
            if let spectrumFeed {
                // Stamped with the ring's frame position, the same clock the render
                // block advances, so the display can look up what is audible now.
                spectrumFeeder.append(
                    interleaved: pcmBuffer,
                    channelCount: ringBuffer.channelCount,
                    frameCount: frameCount,
                    startFrame: Int64(truncatingIfNeeded: chunkStartFrame),
                    sampleRate: detectedSampleRate,
                    to: spectrumFeed,
                    generation: spectrumGeneration
                )
            }
            prebufferedFrames += framesWritten

            if !formatReadyFired && prebufferedFrames >= prebufferThreshold {
                formatReadyFired = true
                onFormatReady(detectedSampleRate, generation)
            }

            if !prebufferReadyFiredOnResume && prebufferedFrames >= resumePrebufferThreshold {
                prebufferReadyFiredOnResume = true
                onPrebufferReady(generation)
            }

            // Exit mid-stream rebuffering once the render thread has enough
            // fresh audio to work with. The render block stays silent until
            // this flag flips back. UI polling picks up the transition.
            if ringBuffer.isRebuffering, ringBuffer.availableFrames >= rebufferRefillThreshold {
                ringBuffer.setRebuffering(false)
            }

            // Emit a bitrate marker tying the ring buffer's post-write frame
            // position to the decoder's cumulative compressed-bytes total.
            // The pipeline computes the displayed bitrate from the markers
            // straddling the ring's read head, so the value reflects what
            // is actually being played — not the bursty decode timing
            // imposed by URLSession backpressure.
            onBitrateMarker(
                ringBuffer.writeHeadFrames,
                decoder.totalCompressedBytes,
                detectedSampleRate,
                generation
            )

            // Request URLSession suspension when the ring is near the cap so
            // a server that's burst-ahead of the bitrate can't outrun the
            // render thread and start dropping data via the ring's drop-oldest
            // path (which would manifest to the user as "same pitch, faster"
            // because the readHead keeps getting pushed forward).
            if ringBuffer.availableFrames >= suspendMark {
                onBackpressureRequest(generation)
            }
        }
    }

    #if DEBUG
    // MARK: - Test Seams (DEBUG only — never compiled into release builds)

    internal func isPausedByUserSnapshotForTesting() -> Bool {
        decodeQueue.sync { isPausedByUser }
    }

    internal func decoderHasQueuedPacketsForTesting() -> Bool {
        decodeQueue.sync { decoder?.hasQueuedPackets ?? false }
    }

    internal func ringBufferAvailableFramesForTesting() -> Int {
        ringBuffer.availableFrames
    }
    #endif
}

// MARK: - URLSession Delegate Proxy

/// Lightweight NSObject that forwards URLSession delegate callbacks.
/// Required because URLSessionDataDelegate needs NSObject conformance.
///
/// @unchecked Sendable: Callback closures are set once in init (immutable after construction),
/// then only read from the URLSession delegate queue. No concurrent mutation.
private final class SessionDelegateProxy: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private let onResponse: @Sendable (URLResponse) -> Void
    private let onData: @Sendable (Data) -> Void
    private let onComplete: @Sendable (Error?) -> Void

    init(
        onResponse: @escaping @Sendable (URLResponse) -> Void,
        onData: @escaping @Sendable (Data) -> Void,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) {
        self.onResponse = onResponse
        self.onData = onData
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        onResponse(response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        onData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onComplete(error)
    }
}
