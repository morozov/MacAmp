import Foundation
import Testing
@testable import MacAmp

@Suite("M3U entry resolution", .tags(.parsing))
struct M3URemoteResolutionTests {
    @Test("A relative entry in a playlist fetched over HTTP resolves like a browser link")
    func remoteRelativeEntry() throws {
        let base = try #require(URL(string: "https://example.com/hls/main/96k.m3u8?user=a&session=b"))
        let result = try M3UParser.parse(content: "#EXTM3U\nchunk_1.ts?user=a&session=b\n", relativeTo: base)
        #expect(result.entries.first?.url.absoluteString == "https://example.com/hls/main/chunk_1.ts?user=a&session=b")
    }

    @Test("A root-relative entry in a playlist fetched over HTTP resolves against the host")
    func remoteRootRelativeEntry() throws {
        let base = try #require(URL(string: "https://example.com/hls/main/96k.m3u8"))
        let result = try M3UParser.parse(content: "#EXTM3U\n/live/chunk_1.ts\n", relativeTo: base)
        #expect(result.entries.first?.url.absoluteString == "https://example.com/live/chunk_1.ts")
    }

    @Test("A relative entry in a local playlist resolves as a file next to it")
    func localRelativeEntry() throws {
        let base = URL(fileURLWithPath: "/tmp/lists/mix.m3u")
        let result = try M3UParser.parse(content: "#EXTM3U\nsong.mp3\n", relativeTo: base)
        let url = try #require(result.entries.first?.url)
        #expect(url.isFileURL)
        #expect(url.path == "/tmp/lists/song.mp3")
    }
}
