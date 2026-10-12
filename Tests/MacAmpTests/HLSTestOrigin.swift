import Foundation

/// A scripted HLS origin for tests. Each media-playlist request takes the next playlist of the
/// script, repeating the last one. Segments answer with `segment(name)`.
final class HLSTestOrigin: @unchecked Sendable {
    private let lock = NSLock()
    private let playlists: [String]
    private var playlistRequests = 0
    private var requested: [URL] = []
    let segment: @Sendable (String) -> (Data, Int)

    init(playlists: [String], segment: @escaping @Sendable (String) -> (Data, Int)) {
        self.playlists = playlists
        self.segment = segment
    }

    /// What the first look at the playlist URL sees, before the loader starts.
    var firstPlaylist: String { playlists[0] }
    var urls: [URL] { lock.withLock { requested } }

    func respond(_ url: URL) -> (data: Data, status: Int, url: URL) {
        lock.withLock {
            requested.append(url)
            if url.pathExtension == "m3u8" {
                let text = playlists[min(playlistRequests, playlists.count - 1)]
                playlistRequests += 1
                return (Data(text.utf8), 200, url)
            }
            let (data, status) = segment(url.lastPathComponent)
            return (data, status, url)
        }
    }

    /// A live playlist of one-second segments `seg<N>.ts`.
    static func playlist(from first: Int, count: Int, ended: Bool = false, discontinuityBefore: Set<Int> = []) -> String {
        var text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:\(first)\n"
        for sequence in first..<(first + count) {
            if discontinuityBefore.contains(sequence) { text += "#EXT-X-DISCONTINUITY\n" }
            text += "#EXTINF:1.000,\nseg\(sequence).ts\n"
        }
        if ended { text += "#EXT-X-ENDLIST\n" }
        return text
    }
}
