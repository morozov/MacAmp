import Foundation
import Testing
@testable import MacAmp

@Suite("HLS playlist", .tags(.parsing))
struct HLSPlaylistTests {
    private let base = URL(string: "https://edge.example.com/hls/main/96k.m3u8")!

    private let live = """
    #EXTM3U
    #EXT-X-TARGETDURATION:5
    #EXT-X-VERSION:3
    #EXT-X-MEDIA-SEQUENCE:358358123
    #EXT-X-DISCONTINUITY-SEQUENCE:0
    #EXTINF:5.000,
    96k_29863176_358358123.ts
    #EXTINF:5.000,
    96k_29863177_358358124.ts
    #EXTINF:4.980,
    96k_29863177_358358125.ts
    """

    private func media(_ content: String) throws -> HLSPlaylist.Media {
        guard case .media(let media) = try HLSPlaylist.parse(content, relativeTo: base) else {
            Issue.record("expected a media playlist")
            throw HLSPlaylist.ParseError.notHLS
        }
        return media
    }

    @Test("A live media playlist yields numbered segments with resolved URLs")
    func liveMediaPlaylist() throws {
        let playlist = try media(live)
        #expect(playlist.targetDuration == 5)
        #expect(playlist.mediaSequence == 358358123)
        #expect(playlist.isEnded == false)
        #expect(playlist.segments.map(\.sequence) == [358358123, 358358124, 358358125])
        #expect(playlist.segments.map(\.duration) == [5.0, 5.0, 4.98])
        #expect(playlist.segments[0].url.absoluteString
                == "https://edge.example.com/hls/main/96k_29863176_358358123.ts")
    }

    @Test("An absolute segment URI is kept as written")
    func absoluteSegmentURI() throws {
        let content = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nhttps://cdn.example.net/a/b.ts\n"
        #expect(try media(content).segments[0].url.absoluteString == "https://cdn.example.net/a/b.ts")
    }

    @Test("CRLF line endings parse like LF")
    func crlf() throws {
        let playlist = try media(live.replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(playlist.segments.count == 3)
    }

    @Test("A discontinuity tag marks only the segment after it")
    func discontinuity() throws {
        let content = """
        #EXTM3U
        #EXT-X-TARGETDURATION:5
        #EXTINF:5.0,
        a.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:5.0,
        b.ts
        #EXTINF:5.0,
        c.ts
        """
        #expect(try media(content).segments.map(\.followsDiscontinuity) == [false, true, false])
    }

    @Test("ENDLIST marks the playlist as ended")
    func endList() throws {
        #expect(try media(live + "\n#EXT-X-ENDLIST\n").isEnded)
    }

    @Test("A media playlist without a target duration is rejected")
    func missingTargetDuration() {
        let content = "#EXTM3U\n#EXT-X-TARGETDURATION\n#EXTINF:5.0,\na.ts\n"
        #expect(throws: HLSPlaylist.ParseError.missingTargetDuration) {
            try HLSPlaylist.parse(content, relativeTo: base)
        }
    }

    @Test("Encryption and initialization segments are reported as unsupported")
    func unsupportedTags() {
        let encrypted = live + "\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n"
        #expect(throws: HLSPlaylist.ParseError.unsupportedEncryption) {
            try HLSPlaylist.parse(encrypted, relativeTo: base)
        }
        let mapped = live + "\n#EXT-X-MAP:URI=\"init.mp4\"\n"
        #expect(throws: HLSPlaylist.ParseError.unsupportedInitSegment) {
            try HLSPlaylist.parse(mapped, relativeTo: base)
        }
        let plain = live + "\n#EXT-X-KEY:METHOD=NONE\n"
        #expect(throws: Never.self) { try HLSPlaylist.parse(plain, relativeTo: base) }
    }

    @Test("Byte-range segments are reported as unsupported")
    func byteRangeIsUnsupported() {
        let content = live + "\n#EXT-X-BYTERANGE:1000@0\n"
        #expect(throws: HLSPlaylist.ParseError.unsupportedByteRange) {
            try HLSPlaylist.parse(content, relativeTo: base)
        }
    }

    @Test("The largest 64-bit media sequence parses, and one that overflows is rejected")
    func mediaSequenceLimits() throws {
        let top = "#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXT-X-MEDIA-SEQUENCE:18446744073709551615\n#EXTINF:5.0,\na.ts\n"
        #expect(try media(top).segments[0].sequence == UInt64.max)

        let overflowing = top + "#EXTINF:5.0,\nb.ts\n"
        #expect(throws: HLSPlaylist.ParseError.invalidMediaSequence) {
            try HLSPlaylist.parse(overflowing, relativeTo: base)
        }

        let tooBig = top.replacingOccurrences(of: "18446744073709551615", with: "18446744073709551616")
        #expect(throws: HLSPlaylist.ParseError.invalidMediaSequence) {
            try HLSPlaylist.parse(tooBig, relativeTo: base)
        }
    }

    @Test("A master playlist offers its variants, and the audio-only one with the least bandwidth wins")
    func masterPlaylist() throws {
        let content = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=1280x720
        video.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS="mp4a.40.2"
        audio128.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS="mp4a.40.5"
        audio64.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=32000,CODECS="avc1.42e00a,mp4a.40.2"
        lowvideo.m3u8
        """
        guard case .master(let master) = try HLSPlaylist.parse(content, relativeTo: base) else {
            Issue.record("expected a master playlist")
            return
        }
        #expect(master.variants.count == 4)
        let chosen = try #require(master.lowestAudioOnlyVariant)
        #expect(chosen.url.absoluteString == "https://edge.example.com/hls/main/audio64.m3u8")
    }

    @Test("A variant with no codecs counts as audio only unless it declares a resolution")
    func variantWithoutCodecs() throws {
        let content = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x360
        video.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=96000
        plain.m3u8
        """
        guard case .master(let master) = try HLSPlaylist.parse(content, relativeTo: base) else {
            Issue.record("expected a master playlist")
            return
        }
        #expect(master.lowestAudioOnlyVariant?.url.lastPathComponent == "plain.m3u8")
    }

    @Test("A master playlist with only video variants has no audio-only variant")
    func noAudioOnlyVariant() throws {
        let content = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=900000,CODECS=\"avc1.4d401f,mp4a.40.2\"\nv.m3u8\n"
        guard case .master(let master) = try HLSPlaylist.parse(content, relativeTo: base) else {
            Issue.record("expected a master playlist")
            return
        }
        #expect(master.lowestAudioOnlyVariant == nil)
    }

    @Test("Plain M3U playlists are not HLS", arguments: [
        "#EXTM3U\n#EXTINF:-1,Station\nhttp://example.com/stream\n",
        "http://example.com/stream\n",
        "",
    ])
    func plainM3UIsNotHLS(content: String) {
        #expect(HLSPlaylist.isHLS(content) == false)
        #expect(throws: HLSPlaylist.ParseError.notHLS) {
            try HLSPlaylist.parse(content, relativeTo: base)
        }
    }

    @Test("Playlists with HLS tags are detected")
    func detection() {
        #expect(HLSPlaylist.isHLS(live))
        #expect(HLSPlaylist.isHLS("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nv.m3u8\n"))
    }
}
