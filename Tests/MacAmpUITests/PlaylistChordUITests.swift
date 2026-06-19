import XCTest

/// Real-pipeline coverage for the playlist clear chord (⌘⇧⌫). The playlist is
/// seeded with five tracks; the test asserts the chord empties it only when the
/// playlist window is key. The negative case proves the chord is not claimed by
/// a global handler and that the window scope holds.
///
/// Crop (⌘⌫) is covered in-process by PlaylistDeleteChordTests; its real-
/// pipeline test needs row-level selection through the accessibility tree,
/// which the custom-drawn rows do not yet expose.
final class PlaylistChordUITests: UIChordTestCase {
    override var extraLaunchEnvironment: [String: String] { ["MACAMP_UITEST_SEED_PLAYLIST": "5"] }

    func test_cmdShiftDelete_clearsPlaylist_onlyWhenPlaylistWindowIsKey() {
        window("MacAmp.PlaylistWindow")
        let probe = app.staticTexts["MacAmp.Playlist.Count"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "playlist count probe not found")
        func count() -> String { probe.value as? String ?? "" }
        XCTAssertEqual(count(), "5", "seed should produce five tracks")

        // Negative: with the main window key, ⌘⇧⌫ must not clear the playlist.
        focusWindow("MacAmp.MainWindow")
        sendKey(.delete, [.command, .shift])
        let afterMain = waitUntil(timeout: 1.5, { count() }, satisfies: { $0 != "5" })
        XCTAssertEqual(afterMain, "5", "⌘⇧⌫ must not clear when the main window is key")

        // Positive: with the playlist window key, ⌘⇧⌫ empties the list.
        focusWindow("MacAmp.PlaylistWindow")
        sendKey(.delete, [.command, .shift])
        let cleared = waitUntil({ count() }, satisfies: { $0 == "0" })
        XCTAssertEqual(cleared, "0", "⌘⇧⌫ should clear the playlist when it is key")
    }

    func test_cmdDelete_cropsToSelectedRow() {
        window("MacAmp.PlaylistWindow")
        let probe = app.staticTexts["MacAmp.Playlist.Count"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "playlist count probe not found")
        func count() -> String { probe.value as? String ?? "" }
        XCTAssertEqual(count(), "5", "seed should produce five tracks")

        // Clicking a row focuses the playlist window and selects that track.
        let row = app.otherElements.matching(identifier: "MacAmp.Playlist.Row.1").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "playlist row not found")
        row.click()

        sendKey(.delete, .command)
        let cropped = waitUntil({ count() }, satisfies: { $0 == "1" })
        XCTAssertEqual(cropped, "1", "⌘⌫ should crop the list to the one selected track")
    }
}
