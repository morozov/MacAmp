import AVFoundation
import Foundation
import Testing
@testable import MacAmp

/// Plays through the real `AudioPlayer` and listens to what it sends to the
/// output: once playback stops or moves to another track, nothing of the old
/// audio may come out. The old audio is a 440 Hz tone and the new a 1 kHz one,
/// so either is recognizable in every captured buffer.
@MainActor
@Suite("Playback switch output", .tags(.audio), .serialized)
struct PlaybackSwitchOutputTests {
    nonisolated static let oldTone = 440.0
    nonisolated static let newTone = 1000.0

    /// A WAV holding one tone per entry of `tones`, each `seconds` long.
    private func makeToneFile(_ tones: [Double], seconds: Double) throws -> URL {
        let sampleRate = 44100.0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("switch-\(UUID().uuidString).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        for tone in tones {
            let frames = AVAudioFrameCount(seconds * sampleRate)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            let step = 2.0 * Double.pi * tone / sampleRate
            for channel in 0..<2 {
                let data = buffer.floatChannelData![channel]
                for i in 0..<Int(frames) { data[i] = Float(0.5 * sin(step * Double(i))) }
            }
            try file.write(from: buffer)
        }
        return url
    }

    private func slice(_ url: URL, start: Double, duration: Double, number: Int) -> Track {
        let slice = CueSlice(startTime: start, duration: duration,
                             cueSheetURL: url.deletingPathExtension().appendingPathExtension("cue"), trackNumber: number)
        return Track(url: url, title: "Track \(number)", artist: "Test", duration: duration, cueSlice: slice)
    }

    @Test("Switching CUE tracks plays nothing of the previous track")
    func cueSwitch() async throws {
        let url = try makeToneFile([Self.oldTone, Self.newTone], seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = AudioPlayer()
        defer { player.stop() }

        player.playTrack(track: slice(url, start: 0, duration: 4, number: 1))
        let capture = try await Capture.start(on: player)
        player.playTrack(track: slice(url, start: 4, duration: 4, number: 2))
        capture.markSwitch()
        try await capture.expectOnlyNewAudio()
    }

    @Test("Starting a track after Stop plays nothing of the stopped one")
    func stopThenPlay() async throws {
        let url = try makeToneFile([Self.oldTone, Self.newTone], seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = AudioPlayer()
        defer { player.stop() }

        player.playTrack(track: slice(url, start: 0, duration: 4, number: 1))
        let capture = try await Capture.start(on: player)
        player.stop()
        player.playTrack(track: slice(url, start: 4, duration: 4, number: 2))
        capture.markSwitch()
        try await capture.expectOnlyNewAudio()
    }

    @Test("Switching to another file plays nothing of the previous one")
    func fileSwitch() async throws {
        let old = try makeToneFile([Self.oldTone], seconds: 4)
        let new = try makeToneFile([Self.newTone], seconds: 4)
        defer {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: new)
        }
        let player = AudioPlayer()
        defer { player.stop() }

        player.playTrack(track: Track(url: old, title: "Old", artist: "Test", duration: 4))
        let capture = try await Capture.start(on: player)
        player.playTrack(track: Track(url: new, title: "New", artist: "Test", duration: 4))
        capture.markSwitch()
        try await capture.expectOnlyNewAudio()
    }

    /// Records each output buffer's position and which tones it carries, from
    /// a moment of steady old playback through the switch that follows.
    private final class Capture: @unchecked Sendable {
        struct Buffer { let sampleTime: AVAudioFramePosition; let frames: Int; let old: Double; let new: Double }

        private let lock = NSLock()
        private var buffers: [Buffer] = []
        private var switchedAt = 0
        private var switchSampleTime: AVAudioFramePosition = 0
        private weak var player: AudioPlayer?

        @MainActor
        static func start(on player: AudioPlayer) async throws -> Capture {
            let capture = Capture()
            capture.player = player
            player.engineForTesting.installOutputTapForTesting { buffer, when in
                capture.record(buffer, at: when.sampleTime)
            }
            // Let the old track play long enough for the reader to queue ahead.
            try await Task.sleep(for: .milliseconds(800))
            let deadline = ContinuousClock.now + .seconds(5)
            while !capture.snapshot().contains(where: { $0.old > Capture.threshold }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let heardOld = capture.snapshot().contains { $0.old > Capture.threshold }
            #expect(heardOld, "the old track never reached the output")
            return capture
        }

        static let threshold = 0.02

        private func record(_ buffer: AVAudioPCMBuffer, at sampleTime: AVAudioFramePosition) {
            guard let data = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            let rate = buffer.format.sampleRate
            let entry = Buffer(sampleTime: sampleTime, frames: frames,
                               old: Self.level(of: PlaybackSwitchOutputTests.oldTone, in: data, frames, rate),
                               new: Self.level(of: PlaybackSwitchOutputTests.newTone, in: data, frames, rate))
            lock.withLock { buffers.append(entry) }
        }

        /// Call right after the switch; the output renders ahead in bursts.
        @MainActor
        func markSwitch() {
            let sampleTime = player?.engineForTesting.outputSampleTimeForTesting ?? 0
            lock.withLock { switchedAt = buffers.count; switchSampleTime = sampleTime }
        }

        private func snapshot() -> [Buffer] {
            lock.withLock { buffers }
        }

        /// The amplitude of `frequency` in the buffer (Goertzel).
        private static func level(of frequency: Double, in data: UnsafePointer<Float>, _ frames: Int, _ rate: Double) -> Double {
            guard frames > 0 else { return 0 }
            let coefficient = 2 * cos(2 * Double.pi * frequency / rate)
            var s1 = 0.0, s2 = 0.0
            for i in 0..<frames {
                let s0 = Double(data[i]) + coefficient * s1 - s2
                s2 = s1; s1 = s0
            }
            let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
            return 2 * power.squareRoot() / Double(frames)
        }

        /// After the switch, the new tone must arrive and the old one must not
        /// appear in any buffer rendered from then on. A new file restarts the
        /// engine, which restarts its sample clock; buffers past that restart
        /// all count as after the switch.
        @MainActor
        func expectOnlyNewAudio() async throws {
            try await Task.sleep(for: .milliseconds(1500))
            player?.engineForTesting.removeOutputTapForTesting()

            let all = snapshot()
            let (from, mark) = lock.withLock { (switchedAt, switchSampleTime) }
            let tail = Array(all[from...])
            // Audio already rendered when the switch was made may still be on
            // its way to the tap; allow one render cycle past the mark.
            let margin: AVAudioFramePosition = 4096
            var after: [Buffer] = []
            var restarted = false
            var previous: AVAudioFramePosition?
            for buffer in tail {
                if let previous, buffer.sampleTime < previous { restarted = true }
                previous = buffer.sampleTime
                if restarted || buffer.sampleTime >= mark + margin { after.append(buffer) }
            }

            #expect(after.contains { $0.new > Self.threshold }, "the new track never reached the output")
            let leaked = after.filter { $0.old > Self.threshold }
            let detail = leaked.map {
                "at \($0.sampleTime - mark) frames, \($0.frames) frames, old \(String(format: "%.3f", $0.old)), new \(String(format: "%.3f", $0.new))"
            }.joined(separator: "; ")
            #expect(leaked.isEmpty, "old track audio after the switch: \(detail)")
        }
    }
}
