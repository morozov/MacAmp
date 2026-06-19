import XCTest

/// End-to-end proof that the `⌘D` double-size chord drives the real pipeline.
///
/// `⌘D` is an existing, implemented binding chosen because its effect — the
/// main window doubling in width — is observable with no media and no
/// playback. It is the template every new chord follows: focus the relevant
/// context, send the chord, assert the observable effect.
final class DoubleSizeChordUITests: UIChordTestCase {
    /// `⌘D` doubles the main window width, and `⌘D` again restores it. If the
    /// binding regressed or another handler swallowed the event, the width
    /// would not change and this fails.
    func test_commandD_togglesMainWindowDoubleSize() {
        mainWindow()
        let normalWidth = mainWindowWidth()
        XCTAssertGreaterThan(normalWidth, 0, "Main window has no measurable width")

        sendChord("d", .command)
        let doubledWidth = waitUntil({ mainWindowWidth() }, satisfies: { $0 > normalWidth * 1.5 })
        XCTAssertEqual(doubledWidth / normalWidth, 2, accuracy: 0.2,
                       "⌘D should double the width (normal \(normalWidth), got \(doubledWidth))")

        sendChord("d", .command)
        let restoredWidth = waitUntil({ mainWindowWidth() }, satisfies: { $0 < normalWidth * 1.5 })
        XCTAssertEqual(restoredWidth, normalWidth, accuracy: 1,
                       "⌘D again should restore the normal width")
    }

    /// A chord MacAmp does not bind must leave the window untouched. Guards the
    /// harness against false positives: it proves the resize above is caused by
    /// the binding, not by any keypress.
    func test_unboundChord_doesNotResize() {
        mainWindow()
        let width = mainWindowWidth()

        sendChord("9", .command)
        let after = waitUntil(timeout: 1.5, { mainWindowWidth() }, satisfies: { $0 != width })
        XCTAssertEqual(after, width, accuracy: 1, "⌘9 is unbound and must not resize the window")
    }
}
