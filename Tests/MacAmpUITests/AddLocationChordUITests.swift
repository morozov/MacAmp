import XCTest

/// Real-pipeline coverage for the ⌘L add-location chord. Pressing ⌘L from a
/// primary window opens the "Add Internet Radio Station" prompt; the test
/// asserts the prompt appears and dismisses it. This exercises the global
/// ⌘-modifier monitor path end to end.
final class AddLocationChordUITests: UIChordTestCase {
    func test_cmdL_opensAddRadioStationPrompt() {
        focusWindow("MacAmp.MainWindow")
        sendChord("l", .command)

        let prompt = app.staticTexts["Add Internet Radio Station"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5),
                      "⌘L should open the Add Internet Radio Station prompt")

        // Leave the app out of its modal loop for teardown (Esc = Cancel).
        sendKey(.escape)
    }
}
