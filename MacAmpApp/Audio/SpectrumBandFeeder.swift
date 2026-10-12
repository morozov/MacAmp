import Foundation

/// Turns runs of decoded audio into analyzer frames on a `SpectrumBandFeed`.
///
/// File playback and stream playback both feed the same analyzer through this
/// type, so the bars cannot depend on which kind of source is playing. Callers
/// hand over each decoded chunk before it is audible, stamped with the frame
/// position its first sample occupies.
///
/// Instances own working buffers and are not thread-safe: confine one to the
/// queue that decodes.
final class SpectrumBandFeeder {
    private let analyzer = SpectrumBandAnalyzer()

    /// Mono mixdown of the chunk being analyzed, plus the tail of the previous
    /// one so a window straddling the boundary still sees real samples.
    private var mono: [Float] = []
    private var carry: [Float] = []
    private var bands = [Float](repeating: 0, count: SpectrumBandAnalyzer.bandCount)

    /// Forget the previous chunk's tail. Call when the next chunk does not
    /// continue the last one.
    func reset() {
        carry = []
    }

    /// Analyze a chunk stored as one buffer per channel.
    func append(
        planar channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int,
        startFrame: Int64,
        sampleRate: Double,
        to feed: SpectrumBandFeed,
        generation: UInt64
    ) {
        guard sampleRate > 0, channelCount > 0 else { return }
        let carried = beginChunk(frameCount: frameCount)

        let scale = 1.0 / Float(channelCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channels[channel][frame]
            }
            mono.append(sum * scale)
        }

        emit(carried: carried, startFrame: startFrame, sampleRate: sampleRate, to: feed, generation: generation)
    }

    /// Analyze a chunk stored as interleaved frames.
    func append(
        interleaved samples: UnsafePointer<Float>,
        channelCount: Int,
        frameCount: Int,
        startFrame: Int64,
        sampleRate: Double,
        to feed: SpectrumBandFeed,
        generation: UInt64
    ) {
        guard sampleRate > 0, channelCount > 0 else { return }
        let carried = beginChunk(frameCount: frameCount)

        let scale = 1.0 / Float(channelCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += samples[frame * channelCount + channel]
            }
            mono.append(sum * scale)
        }

        emit(carried: carried, startFrame: startFrame, sampleRate: sampleRate, to: feed, generation: generation)
    }

    private func beginChunk(frameCount: Int) -> Int {
        let carried = carry.count
        mono.removeAll(keepingCapacity: true)
        mono.append(contentsOf: carry)
        mono.reserveCapacity(carried + frameCount)
        return carried
    }

    /// Emit one analyzer frame per hop across the chunk, stamped with the time
    /// each window ends at.
    private func emit(carried: Int, startFrame: Int64, sampleRate: Double, to feed: SpectrumBandFeed, generation: UInt64) {
        let hop = SpectrumBandAnalyzer.hop
        var end = carried + hop
        while end <= mono.count {
            analyzer.analyze(mono, endingAt: end, into: &bands, at: 0)
            // The window ends here, so this is the audio heard at that instant.
            let time = Double(startFrame + Int64(end - carried)) / sampleRate
            feed.append(bands, at: time, generation: generation)
            end += hop
        }

        // Keep enough tail for the next chunk's first window to reach back into
        // real audio rather than into silence.
        let keep = min(mono.count, SpectrumBandAnalyzer.windowSize)
        carry = Array(mono.suffix(keep))
    }
}
