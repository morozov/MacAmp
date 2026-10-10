import XCTest

/// Dragging a playlist row moves the track with the pointer.
final class PlaylistRowDragUITests: UIChordTestCase {
    override var extraLaunchEnvironment: [String: String] { ["MACAMP_UITEST_SEED_PLAYLIST": "5"] }

    func test_dragRow_movesTrack() {
        let first = app.otherElements.matching(identifier: "MacAmp.Playlist.Row.0").firstMatch
        let third = app.otherElements.matching(identifier: "MacAmp.Playlist.Row.2").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "playlist row not found")

        first.click(forDuration: 0.3, thenDragTo: third)

        let moved = app.otherElements.matching(identifier: "MacAmp.Playlist.Row.2").firstMatch
        let label = waitUntil(timeout: 2, { moved.label }, satisfies: { $0.contains("UITest Track 1") })
        XCTAssertTrue(label.contains("UITest Track 1"), "the first track should land on the third row, got \(label)")
    }
}
