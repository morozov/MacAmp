import AVFoundation
import Foundation
import Testing
@testable import MacAmp

@Suite("Unit-test isolation")
@MainActor
struct UnitTestIsolationTests {
    @Test("The test process is recognized")
    func gateIsActive() {
        #expect(UnitTestSupport.isActive)
    }

    @Test("Persisted files stay out of the user's Application Support")
    func filesStayOutOfApplicationSupport() throws {
        let real = try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let paths = [
            try #require(PlaylistStateStore.playlistFileURL()),
            try AppSettings.ensureSkinsDirectory(),
            try #require(UnitTestSupport.applicationSupportDirectory),
        ]
        for path in paths {
            #expect(!path.standardizedFileURL.path.hasPrefix(real.standardizedFileURL.path), "\(path.path)")
        }
    }

    @Test("Playback reaches the device muted")
    func deviceOutputIsMuted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("isolation-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        buffer.frameLength = 4410
        try file.write(from: buffer)

        let player = AudioPlayer()
        defer { player.stop() }
        try player.engineForTesting.loadFile(url: url)
        #expect(player.engineForTesting.startEngineIfNeeded())
        #expect(player.engineForTesting.deviceOutputVolumeForTesting == 0)
    }
}
