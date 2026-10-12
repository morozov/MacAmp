import Foundation
import Testing
@testable import MacAmp

@MainActor
@Suite("M3U stream titles", .tags(.parsing, .persistence))
struct M3UStreamTitleTests {
    @Test("A stream's title survives repeated save and restore cycles unchanged")
    func streamTitleRoundTrips() throws {
        let url = try #require(URL(string: "https://online.kissfm.ua/KissFM_HD"))
        let player = AudioPlayer()
        player.addEntries([M3UEntry(url: url, title: "online.kissfm.ua", duration: -1, cueSlice: nil)])

        for _ in 0..<3 {
            let content = M3UWriter.serializeState(tracks: player.playlist, currentIndex: nil)
            player.clearPlaylist()
            player.addEntries(try M3UParser.parse(content: content).entries)
        }

        let track = try #require(player.playlist.first)
        #expect(player.playlist.count == 1)
        #expect(track.title == "online.kissfm.ua")
        #expect(track.artist.isEmpty)
    }
}
