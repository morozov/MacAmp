import AVFoundation
import Foundation
import Testing
@testable import MacAmp

/// Exercises the decode-once path end to end: a real file goes through
/// `PlaybackReader` into a real `AVAudioEngine`, and the test checks that the
/// audio arrives at the output, that the analyzer is fed from the same pass,
/// and that the run reports completion.
@Suite("PlaybackReader", .tags(.audio))
struct PlaybackReaderTests {

    /// Write a WAV of a full-scale sine so both the output and the analyzer have
    /// something unambiguous to find.
    private func makeToneFile(seconds: Double, frequency: Double, sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-reader-\(UUID().uuidString).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let data = buffer.floatChannelData![channel]
            let step: Double = 2.0 * Double.pi * frequency / sampleRate
            for i in 0..<Int(frames) {
                let phase: Double = step * Double(i)
                data[i] = Float(0.5 * sin(phase))
            }
        }
        try file.write(from: buffer)
        return url
    }

    @MainActor
    @Test("Decodes into the player and the analyzer feed from one pass")
    func feedsPlayerAndAnalyzer() async throws {
        let sampleRate = 44100.0
        let url = try makeToneFile(seconds: 2.0, frequency: 1000, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0

        let feed = SpectrumBandFeed()
        let ended = Ended()
        let reader = PlaybackReader(playerNode: player, feed: feed) { _ in
            ended.mark()
        }

        engine.prepare()
        try engine.start()

        let file = try AVAudioFile(forReading: url)
        reader.start(url: url, startFrame: 0, endFrame: file.length, outputFormat: format, seekID: nil)
        player.play()

        // Let the reader prime and the engine render a little.
        try await Task.sleep(nanoseconds: 600_000_000)

        // The analyzer must hold frames for audio near the start of the file,
        // which is the whole point: they exist before that audio is due.
        let early = feed.frame(at: 0.05)
        #expect(early != nil, "analyzer feed has no frame for the opening of the file")

        // A 1 kHz tone at twelve bands per octave from bin 1 lands around band
        // 24, and must dominate the bands well away from it.
        if let early {
            #expect(early.count == SpectrumBandAnalyzer.bandCount)
            let peakBand = (early.enumerated().max { $0.element < $1.element })?.offset ?? -1
            #expect((20...29).contains(peakBand), "1 kHz peaked at band \(peakBand)")
            #expect(early[70] < early[peakBand], "high bands should be quiet for a pure tone")
        }

        // Playback actually advanced, so the buffers really were scheduled.
        #expect(player.isPlaying)
        if let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime) {
            #expect(playerTime.sampleTime > 0, "player rendered no frames")
        }

        player.stop()
        engine.stop()
    }

    @MainActor
    @Test("Reports completion at the end of a run")
    func reportsCompletion() async throws {
        let sampleRate = 44100.0
        let url = try makeToneFile(seconds: 0.4, frequency: 440, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0

        let feed = SpectrumBandFeed()
        let ended = Ended()
        let reader = PlaybackReader(playerNode: player, feed: feed) { _ in
            ended.mark()
        }

        engine.prepare()
        try engine.start()
        let file = try AVAudioFile(forReading: url)
        reader.start(url: url, startFrame: 0, endFrame: file.length, outputFormat: format, seekID: nil)
        player.play()

        var waited = 0
        while !ended.value && waited < 40 {
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        #expect(ended.value, "completion never fired for a 0.4 s file")

        player.stop()
        engine.stop()
    }

    @MainActor
    @Test("Converts when the file rate differs from the graph rate")
    func convertsMismatchedRate() async throws {
        // The graph runs at the output device's rate, so a file recorded at a
        // different one has to be converted on the way to the player.
        let url = try makeToneFile(seconds: 1.0, frequency: 1000, sampleRate: 22050)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let graphFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        engine.connect(player, to: engine.mainMixerNode, format: graphFormat)
        engine.mainMixerNode.outputVolume = 0

        let feed = SpectrumBandFeed()
        let reader = PlaybackReader(playerNode: player, feed: feed) { _ in }

        engine.prepare()
        try engine.start()
        let file = try AVAudioFile(forReading: url)
        reader.start(url: url, startFrame: 0, endFrame: file.length, outputFormat: graphFormat, seekID: nil)
        player.play()

        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(feed.frame(at: 0.05) != nil, "no analyzer frames for a resampled file")
        if let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime) {
            #expect(playerTime.sampleTime > 0, "resampled audio never reached the player")
        }

        player.stop()
        engine.stop()
    }

    @Test("A seek drops frames staged for the abandoned position")
    func resetDropsStaleFrames() {
        let feed = SpectrumBandFeed()
        let stale = feed.currentGeneration
        let bands = [Float](repeating: 42, count: SpectrumBandAnalyzer.bandCount)

        feed.append(bands, at: 10.0, generation: stale)
        #expect(feed.frame(at: 10.0) != nil)

        let fresh = feed.reset()
        #expect(feed.frame(at: 10.0) == nil, "reset kept frames from before the seek")

        feed.append(bands, at: 10.0, generation: stale)
        #expect(feed.frame(at: 10.0) == nil, "a frame from the abandoned position was accepted")

        feed.append(bands, at: 10.0, generation: fresh)
        #expect(feed.frame(at: 10.0) != nil, "a frame for the new position was rejected")
    }

    @Test("Frames outside the tolerance are not offered")
    func toleranceBounds() {
        let feed = SpectrumBandFeed()
        let generation = feed.currentGeneration
        feed.append([Float](repeating: 7, count: SpectrumBandAnalyzer.bandCount), at: 5.0, generation: generation)

        #expect(feed.frame(at: 5.0) != nil)
        #expect(feed.frame(at: 5.2) != nil)
        #expect(feed.frame(at: 9.0) == nil, "a frame four seconds away was offered as current")
    }
}

/// Records a completion callback arriving from a background queue.
private final class Ended: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func mark() {
        lock.lock()
        fired = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}
