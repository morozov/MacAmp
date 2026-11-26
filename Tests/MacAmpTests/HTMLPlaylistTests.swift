import Foundation
import Testing
@testable import MacAmp

@Suite("HTML playlist export")
struct HTMLPlaylistTests {
    private func track(_ title: String, duration: Double = 0, artist: String = "") -> Track {
        Track(url: URL(fileURLWithPath: "/music/song.wav"), title: title, artist: artist, duration: duration)
    }

    private var destination: URL { URL(fileURLWithPath: "/exports/Playlist.html") }

    @Test("Unicode titles export in playlist order with HTML metacharacters escaped")
    func titles() throws {
        let tracks = [track("<script>雪 & 'one' \"two\"</script>", duration: 61, artist: "Björk"),
                      track("Last", duration: 3661)]
        let html = try HTMLPlaylistWriter.render(tracks: tracks, destination: destination)
        let first = try #require(html.range(of: "<li>Björk - &lt;script&gt;雪 &amp; &#39;one&#39; &quot;two&quot;&lt;/script&gt; (1:01)"))
        let last = try #require(html.range(of: "<li>Last (61:01)"))
        #expect(first.lowerBound < last.lowerBound)
        #expect(!html.contains("<script>"))
        #expect(html.contains("charset=UTF-8"))
        #expect(html.contains("Winamp Generated PlayList"))
        #expect(html.contains("<p>WINAMP</p>"))
        #expect(html.components(separatedBy: "<li>").count - 1 == tracks.count)
    }

    @Test("Self-save URLs round-trip spaces, Unicode and attribute metacharacters")
    func saveLink() throws {
        let destination = URL(fileURLWithPath: "/exports/雪 & 'mix' \"live\".html")
        let html = try HTMLPlaylistWriter.render(tracks: [track("Song", duration: 1)], destination: destination)
        let start = try #require(html.range(of: "href=\""))
        let remaining = html[start.upperBound...]
        let end = try #require(remaining.firstIndex(of: "\""))
        let attribute = String(remaining[..<end])
        #expect(!attribute.contains("\""))
        #expect(!attribute.contains("'"))
        #expect(attribute.contains("&amp;"))
        let decoded = attribute.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
        let url = try #require(URL(string: decoded))
        #expect(url.path == destination.path)
        #expect(url.isFileURL)
    }

    @Test("Summary estimates unknown durations before truncation", arguments: [1, 3])
    func estimatedLength(unknown: Int) throws {
        let tracks = [track("A", duration: 61), track("B", duration: 62)]
            + (0..<unknown).map { track("Unknown \($0)") }
        let html = try HTMLPlaylistWriter.render(tracks: tracks, destination: destination)
        #expect(html.contains("average track length: <span class=\"val\">1:01</span>"))
        #expect(html.contains("Estimated playlist length:"))
        if unknown == 1 {
            #expect(html.contains("<span class=\"val\">3</span> minutes <span class=\"val\">4</span> seconds"))
            #expect(html.contains("<span class=\"val\">1</span> track of unknown length"))
        } else {
            #expect(html.contains("<span class=\"val\">5</span> minutes <span class=\"val\">7</span> seconds"))
            #expect(html.contains("<span class=\"val\">3</span> tracks of unknown length"))
        }
        #expect(!html.contains("<li>Unknown 0 ("))
    }

    @Test("Known durations format hours in the summary and unbounded minutes in rows")
    func knownLength() throws {
        let html = try HTMLPlaylistWriter.render(tracks: [track("Long", duration: 3661.9)], destination: destination)
        #expect(html.contains("<span class=\"val\">1</span> track in playlist"))
        #expect(html.contains("Playlist length: <span class=\"val\">1</span> hour <span class=\"val\">1</span> minute <span class=\"val\">1</span> second"))
        #expect(html.contains("<li>Long (61:01)"))
        #expect(!html.contains("Estimated"))
    }

    @Test("Empty and unknown-length playlists keep their summary while retaining actual rows")
    func unknownLength() throws {
        let empty = try HTMLPlaylistWriter.render(tracks: [], destination: destination)
        #expect(empty.contains("There are no tracks in the current playlist.<br>"))
        #expect(!empty.contains("<ol>"))
        let tracks = [track("Zero"), track("Negative", duration: -1), track("Infinite", duration: .infinity),
                      track("NaN", duration: .nan)]
        let html = try HTMLPlaylistWriter.render(tracks: tracks, destination: destination)
        #expect(html.contains("There are no tracks in the current playlist.<br>"))
        #expect(html.components(separatedBy: "<li>").count - 1 == tracks.count)
        #expect(!html.contains(" ("))
        let short = try HTMLPlaylistWriter.render(tracks: [track("Short", duration: 0.5)], destination: destination)
        #expect(short.contains("average track length: <span class=\"val\">0:00</span>"))
        #expect(short.contains("<li>Short \n"))
    }

    @MainActor
    @Test("Export snapshots the full playlist and opens the UTF-8 file after a successful write")
    func exportSnapshot() async throws {
        let root = try #require(UnitTestSupport.applicationSupportDirectory)
        let destination = root.appendingPathComponent("export-\(UUID().uuidString).html")
        defer { try? FileManager.default.removeItem(at: destination) }
        let player = AudioPlayer()
        let local = track("雪 & Song", duration: 61)
        let remote = Track(url: try #require(URL(string: "https://example.com/live")), title: "Radio", artist: "", duration: 0)
        [local, remote].forEach(player.playlistController.addTrack)
        let actions = PlaylistWindowActions()
        actions.selectedIndices = [1]
        var opened: [URL] = []
        var contentsAtOpen: String?
        let task = actions.generateHTMLPlaylist(audioPlayer: player, destination: destination, open: { url in
            opened.append(url)
            contentsAtOpen = try? String(contentsOf: url, encoding: .utf8)
        }, report: { _, _ in Issue.record("Export unexpectedly failed") })
        player.clearPlaylist()
        await task.value
        #expect(opened == [destination])
        let html = try #require(contentsAtOpen)
        #expect(html == (try HTMLPlaylistWriter.render(tracks: [local, remote], destination: destination)))
        #expect(try Data(contentsOf: destination) == Data(html.utf8))
        #expect(player.playlist.isEmpty)
    }

    @Test("An unresolved final CUE duration exports as unknown alongside a known row")
    func cueDurationSentinel() throws {
        var unresolved = track("Final slice", duration: .greatestFiniteMagnitude)
        unresolved.cueSlice = CueSlice(startTime: 0, duration: .greatestFiniteMagnitude,
                                       cueSheetURL: URL(fileURLWithPath: "/music/album.cue"), trackNumber: 1)
        let html = try HTMLPlaylistWriter.render(tracks: [track("Known", duration: 61), unresolved], destination: destination)
        #expect(html.contains("<span class=\"val\">2</span> tracks in playlist"))
        #expect(html.contains("<span class=\"val\">2</span> minutes <span class=\"val\">2</span> seconds"))
        #expect(html.contains("<span class=\"val\">1</span> track of unknown length"))
        #expect(html.contains("<li>Final slice \n"))
    }

    @Test("Unrepresentable sums and estimates reject rendering", arguments: [false, true])
    func durationOverflow(estimate: Bool) {
        let large = track("Large", duration: Double(1 << 62))
        let tracks = estimate ? [large, track("Unknown A"), track("Unknown B")] : [large, large]
        #expect(throws: HTMLPlaylistWriter.RenderError.durationOverflow) {
            try HTMLPlaylistWriter.render(tracks: tracks, destination: destination)
        }
    }

    @Test("Representable large totals and estimates retain exact integer seconds")
    func exactLargeTotals() throws {
        let sum = try HTMLPlaylistWriter.render(
            tracks: [track("A", duration: Double(1 << 62)), track("B", duration: Double((1 << 62) - 512))],
            destination: destination
        )
        #expect(sum.contains("<span class=\"val\">2562047788015215</span> hours <span class=\"val\">21</span> minutes <span class=\"val\">36</span> seconds"))
        let estimate = try HTMLPlaylistWriter.render(
            tracks: [track("A", duration: Double((1 << 52) + 1)), track("B", duration: Double(1 << 52)),
                     track("Unknown A"), track("Unknown B"), track("Unknown C")],
            destination: destination
        )
        #expect(estimate.contains("<span class=\"val\">6254999482459</span> hours <span class=\"val\">1</span> minute <span class=\"val\">22</span> seconds"))
    }

    @MainActor
    @Test("An overflowing export reports the error before creating or opening the file")
    func exportOverflow() async throws {
        let root = try #require(UnitTestSupport.applicationSupportDirectory)
        let destination = root.appendingPathComponent("overflow-\(UUID().uuidString).html")
        defer { try? FileManager.default.removeItem(at: destination) }
        let player = AudioPlayer()
        [track("A", duration: Double(1 << 62)), track("B", duration: Double(1 << 62))]
            .forEach(player.playlistController.addTrack)
        var opened = false
        var errors: [String] = []
        await PlaylistWindowActions().generateHTMLPlaylist(
            audioPlayer: player, destination: destination,
            open: { _ in opened = true }, report: { errors = [$0, $1] }
        ).value
        #expect(!opened)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(errors == ["Error", "Error writing HTML file."])
    }

    @MainActor
    @Test("A failed write reports the error without opening a browser")
    func writeFailure() async throws {
        let root = try #require(UnitTestSupport.applicationSupportDirectory)
        let destination = root.appendingPathComponent("blocked-\(UUID().uuidString).html", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let player = AudioPlayer()
        var opened = false
        var errors: [String] = []
        await PlaylistWindowActions().generateHTMLPlaylist(
            audioPlayer: player, destination: destination,
            open: { _ in opened = true }, report: { errors = [$0, $1] }
        ).value
        #expect(!opened)
        #expect(errors == ["Error", "Error writing HTML file."])
    }
}
