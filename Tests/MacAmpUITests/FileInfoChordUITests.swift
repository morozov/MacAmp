import XCTest

/// Real-pipeline coverage for the ⌥3 File Info chord — the Winamp-faithful
/// binding (Winamp's `Alt+3`). With a track to describe, ⌥3 opens the File Info
/// window; with nothing loaded, it opens nothing.
final class FileInfoChordUITests: UIChordTestCase {
    override var extraLaunchEnvironment: [String: String] { ["MACAMP_UITEST_SEED_PLAYLIST": "5"] }

    func test_option3_opensFileInfo() {
        // Clicking a row focuses the playlist window and selects that track,
        // which is the target File Info resolves.
        let row = app.otherElements.matching(identifier: "MacAmp.Playlist.Row.1").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "playlist row not found")
        row.click()

        sendChord("3", .option)

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5),
                      "⌥3 should open the File Info window")

        done.click()
    }

    func test_stepButtons_walkThePlaylist() {
        let row = app.otherElements.matching(identifier: "MacAmp.Playlist.Row.0").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "playlist row not found")
        row.click()

        sendChord("3", .option)

        let previous = app.buttons["<<"]
        let next = app.buttons[">>"]
        XCTAssertTrue(previous.waitForExistence(timeout: 5), "File Info should show the step buttons")
        XCTAssertFalse(previous.isEnabled, "<< should be disabled on the first entry")
        XCTAssertTrue(next.isEnabled, ">> should be enabled on the first entry")

        next.click()
        XCTAssertTrue(waitUntil(timeout: 2, { previous.isEnabled }, satisfies: { $0 }),
                      ">> should step off the first entry")

        app.buttons["Done"].click()
    }

    func test_option3_doesNothing_withNoTrack() {
        focusWindow("MacAmp.MainWindow")
        sendChord("3", .option)

        let done = app.buttons["Done"]
        let appeared = waitUntil(timeout: 2, { done.exists }, satisfies: { $0 })
        XCTAssertFalse(appeared,
                       "⌥3 should open nothing when no track is selected or playing")
    }
}
