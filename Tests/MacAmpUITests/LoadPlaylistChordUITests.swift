import XCTest

/// Real-pipeline coverage for the ⌘O load-playlist chord. ⌘O now opens the
/// "Load Playlist" file panel — the Winamp-faithful binding — rather than
/// Open Files, which keeps plain `L` and its menu item. The test presses ⌘O
/// and asserts the panel appears, then dismisses it.
final class LoadPlaylistChordUITests: UIChordTestCase {
    func test_cmdO_opensLoadPlaylistPanel() {
        focusWindow("MacAmp.MainWindow")
        sendChord("o", .command)

        let panelMessage = app.staticTexts["Select an M3U playlist file"]
        XCTAssertTrue(panelMessage.waitForExistence(timeout: 5),
                      "⌘O should open the Load Playlist file panel")

        sendKey(.escape)
    }
}
