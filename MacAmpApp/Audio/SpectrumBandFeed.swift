import Foundation
import os

/// Analyzer frames stamped with the playback position they describe.
///
/// The decoder fills this ahead of the playhead, and the display asks for the
/// frame matching what is audible right now. Because the frames arrive before
/// they are due, the analyzer tracks the audio instead of trailing it — a tap
/// on the engine's output can only describe audio that has already been
/// rendered, and only in the 100 ms lumps the platform delivers.
///
/// Written from the decode queue and read from the main thread, so both sides
/// go through a lock. Writers hold it only for a memcpy-sized region.
final class SpectrumBandFeed: @unchecked Sendable {
    /// Frames retained before the oldest is overwritten. At one frame per 256
    /// samples this holds about three seconds at 44.1 kHz, comfortably more
    /// than the decoder reads ahead.
    private static let capacity = 512

    private let width = SpectrumBandAnalyzer.bandCount

    private var frames: [Float]
    /// Playback time each frame describes, in seconds from the start of the file.
    private var times: [Double]
    private var writeIndex = 0
    private var count = 0
    /// Bumped on every reset so a frame from a superseded seek can be recognized
    /// and dropped.
    private var generation: UInt64 = 0

    private var lock = os_unfair_lock()

    init() {
        frames = Array(repeating: 0, count: Self.capacity * SpectrumBandAnalyzer.bandCount)
        times = Array(repeating: 0, count: Self.capacity)
    }

    /// Discard every frame and start a new generation.
    /// - Returns: The generation that appended frames must now carry.
    @discardableResult
    func reset() -> UInt64 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        writeIndex = 0
        count = 0
        generation &+= 1
        return generation
    }

    /// The generation an appender should carry until the next reset.
    var currentGeneration: UInt64 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return generation
    }

    /// Store one frame, ignoring it if a reset has since superseded `generation`.
    func append(_ bands: [Float], at time: Double, generation: UInt64) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard generation == self.generation, bands.count >= width else { return }

        let base = writeIndex * width
        for i in 0..<width {
            frames[base + i] = bands[i]
        }
        times[writeIndex] = time
        writeIndex = (writeIndex + 1) % Self.capacity
        count = min(count + 1, Self.capacity)
    }

    /// The frame describing `time`, or nil when the feed holds nothing close
    /// enough to it.
    ///
    /// - Parameter tolerance: How far a frame may sit from `time` and still be
    ///   used. Beyond it the feed is treated as having no answer, so a caller
    ///   can fall back rather than draw stale bars.
    func frame(at time: Double, tolerance: Double = 0.25) -> [Float]? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard count > 0 else { return nil }

        var bestIndex = -1
        var bestDistance = Double.greatestFiniteMagnitude
        for i in 0..<count {
            let index = (writeIndex - 1 - i + Self.capacity * 2) % Self.capacity
            let distance = abs(times[index] - time)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            } else if bestDistance <= 0.01 {
                // Times descend as the scan walks back, so once it starts
                // moving away from a near-exact hit there is nothing better left.
                break
            }
        }

        guard bestIndex >= 0, bestDistance <= tolerance else { return nil }
        let base = bestIndex * width
        return Array(frames[base..<(base + width)])
    }
}
