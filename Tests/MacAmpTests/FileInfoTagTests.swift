import Foundation
import Testing
@testable import MacAmp

/// Reads tags from one second of silence tagged the same way in two formats:
/// ID3v2.4 frames in `tagged.mp3`, Vorbis comments in `tagged.flac`.
@Suite("FileInfo tags", .tags(.audio, .parsing))
struct FileInfoTagTests {
    private final class BundleToken {}

    @Test("Every field the dialog shows is read from the file's tags",
          arguments: ["tagged.mp3", "tagged.flac"])
    func readsAllFields(fixture: String) async throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: fixture, withExtension: nil))
        let info = await MetadataLoader.loadFileInfo(from: url)
        let mp3 = fixture.hasSuffix(".mp3")

        #expect(info.title == "Fixture Title")
        #expect(info.artist == "Fixture Artist")
        #expect(info.album == "Fixture Album")
        #expect(info.albumArtist == "Fixture Album Artist")
        #expect(info.trackNumber == (mp3 ? "3/12" : "3"))
        #expect(info.discNumber == (mp3 ? "2/4" : "2"))
        #expect(info.year == "2021")
        #expect(info.genre == "Trance")
        #expect(info.comment == "Fixture Comment")
        #expect(info.composer == "Fixture Composer")
        #expect(info.publisher == "Fixture Publisher")
        #expect(info.bpm == "128")
        #expect(info.trackGain == "-6.50 dB")
        #expect(info.albumGain == "-7.25 dB")
    }
}
