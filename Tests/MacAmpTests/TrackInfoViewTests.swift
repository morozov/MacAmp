import Foundation
import Testing
@testable import MacAmp

@Suite("TrackInfoView", .tags(.parsing))
struct TrackInfoViewTests {
    private let url = URL(fileURLWithPath: "/tmp/album.flac")

    private var tags: FileInfo {
        var info = FileInfo()
        info.title = "Album Title"
        info.artist = "Album Artist"
        return info
    }

    @Test("A plain track shows the file's tags")
    func plainTrackPrefersTags() {
        let track = Track(url: url, title: "Entry Title", artist: "Entry Artist", duration: 60)
        #expect(TrackInfoView.title(of: track, info: tags) == "Album Title")
        #expect(TrackInfoView.artist(of: track, info: tags) == "Album Artist")
    }

    @Test("A plain track without tags falls back to the playlist entry")
    func plainTrackFallsBackToEntry() {
        let track = Track(url: url, title: "Entry Title", artist: "Entry Artist", duration: 60)
        #expect(TrackInfoView.title(of: track, info: FileInfo()) == "Entry Title")
        #expect(TrackInfoView.artist(of: track, info: FileInfo()) == "Entry Artist")
    }

    @Test("A CUE sheet track shows its own title and artist over the file's tags")
    func cueTrackPrefersEntry() {
        let slice = CueSlice(startTime: 60, duration: 60, cueSheetURL: URL(fileURLWithPath: "/tmp/album.cue"), trackNumber: 2)
        let track = Track(url: url, title: "Cue Title", artist: "Cue Artist", duration: 60, cueSlice: slice)
        #expect(TrackInfoView.title(of: track, info: tags) == "Cue Title")
        #expect(TrackInfoView.artist(of: track, info: tags) == "Cue Artist")
    }

    @Test("A plain track shows the file's track number")
    func plainTrackNumber() {
        var info = tags
        info.trackNumber = "02"
        let track = Track(url: url, title: "Entry Title", artist: "Entry Artist", duration: 60)
        #expect(TrackInfoView.trackNumber(of: track, info: info) == "02")
    }

    @Test("A CUE sheet track shows the sheet's track number, never the file's",
          arguments: [(Int?.some(5), String?.some("5")), (nil, nil)])
    func cueTrackNumber(sheetNumber: Int?, expected: String?) {
        var info = tags
        info.trackNumber = "02"
        let slice = CueSlice(startTime: 60, duration: 60, cueSheetURL: URL(fileURLWithPath: "/tmp/album.cue"), trackNumber: sheetNumber)
        let track = Track(url: url, title: "Cue Title", artist: "Cue Artist", duration: 60, cueSlice: slice)
        #expect(TrackInfoView.trackNumber(of: track, info: info) == expected)
    }
}
