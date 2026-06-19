import XCTest

/// End-to-end coverage for the equalizer window-local bare keys (`N`, `A`).
///
/// These run on a dispatch surface that did not exist before — a key monitor
/// scoped to the equalizer window — so they are the real justification for the
/// harness. The on/off test is deliberately context-sensitive: `N` must toggle
/// the EQ when the equalizer window is key and do nothing when the main window
/// is key. That negative case is what catches a global handler wrongly claiming
/// the key, or the scoped monitor leaking outside its window.
final class EqualizerChordUITests: UIChordTestCase {
    private let onOff = "MacAmp.EQ.OnOff"
    private let auto = "MacAmp.EQ.Auto"

    func test_n_togglesEqOnOff_onlyWhenEqualizerWindowIsKey() {
        window("MacAmp.EqualizerWindow")
        XCTAssertTrue(app.buttons[onOff].waitForExistence(timeout: 10), "EQ on/off control not found")

        // Negative: with the main window key, plain N must not touch the EQ.
        focusWindow("MacAmp.MainWindow")
        let initial = value(of: onOff)
        sendChord("n")
        let afterMain = waitUntil(timeout: 1.5, { value(of: onOff) }, satisfies: { $0 != initial })
        XCTAssertEqual(afterMain, initial, "N must not toggle the EQ when the main window is key")

        // Positive: with the equalizer window key, N toggles on/off.
        focusWindow("MacAmp.EqualizerWindow")
        sendChord("n")
        let toggled = waitUntil({ value(of: onOff) }, satisfies: { $0 != initial })
        XCTAssertNotEqual(toggled, initial, "N should toggle the EQ on/off when the equalizer window is key")
    }

    func test_a_togglesEqAuto_whenEqualizerWindowIsKey() {
        window("MacAmp.EqualizerWindow")
        XCTAssertTrue(app.buttons[auto].waitForExistence(timeout: 10), "EQ auto control not found")

        focusWindow("MacAmp.EqualizerWindow")
        let initial = value(of: auto)
        sendChord("a")
        let toggled = waitUntil({ value(of: auto) }, satisfies: { $0 != initial })
        XCTAssertNotEqual(toggled, initial, "A should toggle EQ auto when the equalizer window is key")
    }
}
