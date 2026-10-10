import Foundation
import Testing
@testable import MacAmp

@Suite("M3U CUE slices", .tags(.parsing, .persistence))
struct M3UCueSliceTests {
    private let file = URL(fileURLWithPath: "/tmp/album.flac")
    private let sheet = URL(fileURLWithPath: "/tmp/album, live.cue")

    private func roundTrip(_ slice: CueSlice) throws -> CueSlice? {
        let track = Track(url: file, title: "Title", artist: "Artist", duration: slice.duration, cueSlice: slice)
        let content = M3UWriter.serializeState(tracks: [track], currentIndex: nil)
        return try M3UParser.parse(content: content).entries.first?.cueSlice
    }

    @Test("The sheet's track number survives a save and restore")
    func trackNumberRoundTrips() throws {
        let slice = CueSlice(startTime: 294.72, duration: 247.5, cueSheetURL: sheet, trackNumber: 2)
        #expect(try roundTrip(slice) == slice)
    }

    @Test("A slice without a track number restores without one")
    func missingTrackNumberRoundTrips() throws {
        let slice = CueSlice(startTime: 0, duration: 294.72, cueSheetURL: sheet, trackNumber: nil)
        #expect(try roundTrip(slice) == slice)
    }

    @Test("A playlist saved before track numbers restores its slices")
    func legacyDirectiveParses() throws {
        let content = """
        #EXTM3U
        #EXTMACAMP-VERSION:1
        #EXTINF:294,Artist - Title
        #EXTMACAMP-CUE:start=0.0,duration=294.72,sheet=/tmp/album%2C live.cue
        /tmp/album.flac
        """
        let slice = try M3UParser.parse(content: content).entries.first?.cueSlice
        #expect(slice == CueSlice(startTime: 0, duration: 294.72, cueSheetURL: sheet, trackNumber: nil))
    }
}
