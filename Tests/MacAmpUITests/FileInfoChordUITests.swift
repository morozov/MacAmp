import XCTest

/// Real-pipeline coverage for the ⌥3 File Info chord — the Winamp-faithful
/// binding (Winamp's `Alt+3`). Pressing ⌥3 from a primary window opens the
/// File Info dialog; the test asserts the dialog appears and dismisses it.
final class FileInfoChordUITests: UIChordTestCase {
    func test_option3_opensFileInfo() {
        focusWindow("MacAmp.MainWindow")
        sendChord("3", .option)

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5),
                      "⌥3 should open the File Info dialog")

        done.click()
    }
}
