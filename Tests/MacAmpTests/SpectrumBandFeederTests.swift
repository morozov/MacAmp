import Foundation
import Testing
@testable import MacAmp

/// Files hand the feeder planar chunks and streams hand it interleaved ones.
/// The same audio must come out as the same bars either way.
@Suite("Spectrum band feeder", .tags(.audio))
struct SpectrumBandFeederTests {
    private let sampleRate = 44100.0
    private let frameCount = 8192

    private func tone() -> (left: [Float], right: [Float]) {
        let left = (0..<frameCount).map { 0.5 * sin(2 * Float.pi * 1000 * Float($0) / Float(sampleRate)) }
        let right = (0..<frameCount).map { 0.25 * sin(2 * Float.pi * 3000 * Float($0) / Float(sampleRate)) }
        return (left, right)
    }

    @Test("A stream's interleaved chunk produces the same frames as a file's planar chunk")
    func interleavedMatchesPlanar() {
        var (left, right) = tone()
        let interleaved = zip(left, right).flatMap { [$0, $1] }

        let planarFeed = SpectrumBandFeed()
        let planarGeneration = planarFeed.currentGeneration
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var channels = [l.baseAddress!, r.baseAddress!]
                SpectrumBandFeeder().append(
                    planar: &channels, channelCount: 2, frameCount: frameCount,
                    startFrame: 0, sampleRate: sampleRate, to: planarFeed, generation: planarGeneration
                )
            }
        }

        let interleavedFeed = SpectrumBandFeed()
        let interleavedGeneration = interleavedFeed.currentGeneration
        interleaved.withUnsafeBufferPointer { samples in
            SpectrumBandFeeder().append(
                interleaved: samples.baseAddress!, channelCount: 2, frameCount: frameCount,
                startFrame: 0, sampleRate: sampleRate, to: interleavedFeed, generation: interleavedGeneration
            )
        }

        for time in [0.05, 0.1, 0.15] {
            let expected = planarFeed.frame(at: time)
            #expect(expected != nil)
            #expect(expected?.contains { $0 > 0 } == true)
            #expect(interleavedFeed.frame(at: time) == expected)
        }
    }

    @Test("Frames are stamped from the chunk's start position")
    func framesCarryTheChunkPosition() {
        let (left, right) = tone()
        let interleaved = zip(left, right).flatMap { [$0, $1] }
        let feed = SpectrumBandFeed()
        let start: Int64 = 44100 * 10
        interleaved.withUnsafeBufferPointer { samples in
            SpectrumBandFeeder().append(
                interleaved: samples.baseAddress!, channelCount: 2, frameCount: frameCount,
                startFrame: start, sampleRate: sampleRate, to: feed, generation: feed.currentGeneration
            )
        }

        #expect(feed.frame(at: 10.1) != nil)
        #expect(feed.frame(at: 0.1) == nil)
    }

    @Test("The feed keeps a full stream ring buffer's worth of frames")
    func feedCoversTheStreamRingBuffer() {
        let ringFrames = 480_000
        let interleaved = (0..<ringFrames).flatMap { n -> [Float] in
            let sample = 0.5 * sin(2 * Float.pi * 1000 * Float(n) / Float(sampleRate))
            return [sample, sample]
        }
        let feed = SpectrumBandFeed()
        interleaved.withUnsafeBufferPointer { samples in
            SpectrumBandFeeder().append(
                interleaved: samples.baseAddress!, channelCount: 2, frameCount: ringFrames,
                startFrame: 0, sampleRate: sampleRate, to: feed, generation: feed.currentGeneration
            )
        }

        #expect(feed.frame(at: 0.1) != nil)
    }
}
