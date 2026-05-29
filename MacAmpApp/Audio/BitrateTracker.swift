import Foundation

/// Render-driven bitrate computation, source-agnostic.
///
/// A `BitrateTracker` owns a list of `(framePosition, cumulativeCompressedBytes)`
/// markers and answers one question: "given the audio that's been rendered up
/// to `renderFramePosition`, what was its encoded bitrate over the last
/// `windowSeconds`?". The frame coordinate system is chosen by the caller —
/// it can be a ring-buffer write head (HTTP stream) or a sample offset
/// inside a local file — the tracker only requires markers and queries to
/// use the same one.
///
/// Source-specific concerns (how markers are produced, what the current
/// render position is) live in the source components; this class is the
/// shared, identical computation that all sources share so the displayed
/// bitrate behaves the same regardless of where the audio came from.
@MainActor
final class BitrateTracker {

    /// Sendable so feeders that build markers off the main actor (e.g.
    /// `LocalFilePacketScanner` scanning an audio file in the background)
    /// can hand a list across actor isolation in one shot.
    struct Marker: Sendable {
        let framePosition: UInt64
        let cumulativeCompressedBytes: UInt64
    }

    /// Width of the playback window used by `bitrate(renderFramePosition:sampleRate:)`,
    /// in seconds of *rendered* audio. Short enough that VBR fluctuation is
    /// perceptible, long enough to absorb single-packet noise.
    static let windowSeconds: Double = 1.0

    private var markers: [Marker] = []

    func reset() {
        markers.removeAll()
    }

    /// Build a 2-marker seed table from a known total frame count and a
    /// total compressed byte count. Combined with the interpolating
    /// `bytesAtFramePosition`, the resulting tracker reports the
    /// lifetime-average bitrate at any in-range render position — useful
    /// as a synchronous placeholder while a detailed per-packet scan is
    /// still in flight, and as the canonical representation for CBR
    /// content (which has no VBR variation to surface).
    static func seedMarkers(totalFrames: UInt64, totalCompressedBytes: UInt64) -> [Marker] {
        guard totalFrames > 0, totalCompressedBytes > 0 else { return [] }
        return [
            .init(framePosition: 0, cumulativeCompressedBytes: 0),
            .init(framePosition: totalFrames, cumulativeCompressedBytes: totalCompressedBytes),
        ]
    }

    func appendMarker(framePosition: UInt64, cumulativeCompressedBytes: UInt64) {
        markers.append(.init(
            framePosition: framePosition,
            cumulativeCompressedBytes: cumulativeCompressedBytes
        ))
    }

    /// Bulk-replace the marker list — used by feeders that produce the
    /// full table up front (e.g. local-file pre-scan).
    func replaceMarkers(_ items: [Marker]) {
        markers = items
    }

    /// Bitrate (bits/second) over the last `windowSeconds` of *rendered*
    /// audio ending at `renderFramePosition`. Returns 0 if the markers do
    /// not yet span a non-empty interval.
    func bitrate(renderFramePosition: UInt64, sampleRate: Float64) -> Int {
        guard sampleRate > 0 else { return 0 }
        let windowFrames = UInt64(sampleRate * Self.windowSeconds)
        let windowStart = renderFramePosition > windowFrames
            ? renderFramePosition &- windowFrames
            : 0

        let endBytes = bytesAtFramePosition(renderFramePosition)
        let startBytes = bytesAtFramePosition(windowStart)
        guard endBytes > startBytes else { return 0 }
        let framesDelta = renderFramePosition &- windowStart
        guard framesDelta > 0 else { return 0 }
        let durationSeconds = Double(framesDelta) / sampleRate
        return Int(Double(endBytes &- startBytes) * 8.0 / durationSeconds)
    }

    /// Drop markers strictly older than `cutoff`, keeping at most one
    /// anchor before the cutoff (so `bytesAtFramePosition(cutoff)` still
    /// returns a real value). The caller is responsible for deciding when
    /// to prune — streams prune as the read head advances; static
    /// (pre-scanned) trackers never need to.
    func pruneBelow(framePosition cutoff: UInt64) {
        while markers.count > 1, markers[1].framePosition <= cutoff {
            markers.removeFirst()
        }
    }

    /// Interpolated lookup of cumulative compressed bytes at an arbitrary
    /// frame position. With dense markers this approximates the true
    /// cumulative byte count; with two markers (CBR fast path, synchronous
    /// lifetime-rate seed) it returns the exact constant-rate value at any
    /// in-range position, which is why those code paths only need to emit a
    /// pair of markers `(0, 0)` and `(totalFrames, totalBytes)` to drive a
    /// correct display.
    ///
    /// Outside the marker range:
    /// - Before the first marker: 0.
    /// - At or after the last marker: that marker's bytes (clamped — a
    ///   stream whose markers are momentarily behind the render head
    ///   shouldn't suddenly read 0).
    private func bytesAtFramePosition(_ framePos: UInt64) -> UInt64 {
        guard let last = markers.last else { return 0 }
        if framePos >= last.framePosition { return last.cumulativeCompressedBytes }
        guard let first = markers.first, framePos >= first.framePosition else { return 0 }

        // Binary search for the largest index i with markers[i].framePosition <= framePos.
        // Markers are appended in monotonic order, so this is well-defined.
        var lo = 0
        var hi = markers.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if markers[mid].framePosition <= framePos {
                lo = mid
            } else {
                hi = mid - 1
            }
        }

        let lower = markers[lo]
        // framePos < last.framePosition (guarded above), so lo < markers.count - 1.
        let upper = markers[lo + 1]
        let frameSpan = upper.framePosition &- lower.framePosition
        guard frameSpan > 0 else { return lower.cumulativeCompressedBytes }
        let byteSpan = upper.cumulativeCompressedBytes &- lower.cumulativeCompressedBytes
        let frameOffset = framePos &- lower.framePosition
        return lower.cumulativeCompressedBytes &+ (byteSpan &* frameOffset / frameSpan)
    }
}

/// Source-specific façade over a `BitrateTracker`. Each playback source
/// (HTTP stream, local file) implements this so callers can ask "what is
/// the bitrate of what's playing right now?" without branching on source.
@MainActor
protocol BitrateSource: AnyObject {
    /// The shared tracker for this source. Stream sources populate it as
    /// they decode; static (pre-scanned) sources populate it at load time.
    var bitrateTracker: BitrateTracker { get }

    /// Current render position in the same frame coordinate system the
    /// markers use. For HTTP streams: ring buffer `readHead`. For local
    /// files: cumulative sample offset within the file.
    var renderFramePosition: UInt64 { get }

    /// Sample rate of the rendered audio, used to convert the bitrate
    /// window (1 s) into a frame distance.
    var renderSampleRate: Float64 { get }
}

extension BitrateSource {
    /// Convenience: ask the tracker for the current bitrate using this
    /// source's render position and sample rate. Source-agnostic call site.
    var currentBitrate: Int {
        bitrateTracker.bitrate(
            renderFramePosition: renderFramePosition,
            sampleRate: renderSampleRate
        )
    }
}
