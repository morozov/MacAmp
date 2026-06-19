import XCTest

/// Base class for keyboard-chord UI tests.
///
/// Each test launches MacAmp in the deterministic `MACAMP_UITEST` mode — no
/// restored playlist, no playback — with toggle defaults forced volatile
/// through the NSUserDefaults argument domain, so every run starts from the
/// same known window state and never touches the user's saved preferences.
///
/// The point of this layer is the one thing unit tests cannot prove: that a
/// real key event, delivered through the live OS event pipeline to the focused
/// window, reaches MacAmp's monitor and produces the action's observable
/// effect — and is not silently swallowed by another monitor or the responder
/// chain. A failing chord shows up here as a missing effect.
class UIChordTestCase: XCTestCase {
    private(set) var app: XCUIApplication!

    /// Extra launch-environment entries a subclass needs, e.g. seeding the
    /// playlist. Merged on top of the deterministic-mode default.
    var extraLaunchEnvironment: [String: String] { [:] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Deterministic mode: the app reads settings from a wiped, isolated
        // UserDefaults suite, so every run starts from a normal-size,
        // non-shaded, empty-playlist state with no further setup.
        app.launchEnvironment["MACAMP_UITEST"] = "1"
        for (key, value) in extraLaunchEnvironment { app.launchEnvironment[key] = value }
        app.launch()
    }

    override func tearDownWithError() throws {
        // Never leave a MacAmp instance running between or after tests.
        app?.terminate()
        app = nil
    }

    // MARK: - Helpers

    /// The main window element, once it appears in the accessibility tree.
    @discardableResult
    func mainWindow(timeout: TimeInterval = 15) -> XCUIElement {
        let window = app.windows["MacAmp.MainWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: timeout), "Main window did not appear")
        return window
    }

    /// Current main-window width, re-queried fresh each call.
    func mainWindowWidth() -> CGFloat {
        app.windows["MacAmp.MainWindow"].frame.width
    }

    /// A window by accessibility identifier, once it appears.
    @discardableResult
    func window(_ identifier: String, timeout: TimeInterval = 15) -> XCUIElement {
        let element = app.windows[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Window \(identifier) did not appear")
        return element
    }

    /// Makes a window the key window by clicking into it. The titlebar is a
    /// custom drag handle that does not activate the window on a tap, so this
    /// clicks the window body instead; any control thereby hit has no bearing
    /// on the state these tests observe.
    func focusWindow(_ identifier: String) {
        app.windows[identifier].click()
    }

    /// The accessibility value of a control, re-queried fresh each call.
    func value(of identifier: String) -> String {
        app.buttons[identifier].value as? String ?? ""
    }

    /// Sends a key chord to the focused app through the real event pipeline.
    func sendChord(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags = []) {
        app.typeKey(key, modifierFlags: modifiers)
    }

    /// Sends a special key (e.g. `.delete`) with modifiers through the pipeline.
    func sendKey(_ key: XCUIKeyboardKey, _ modifiers: XCUIElement.KeyModifierFlags = []) {
        app.typeKey(key, modifierFlags: modifiers)
    }

    /// Polls `value` until `predicate` holds or the timeout elapses, then
    /// returns the last sample. Lets a test wait on an async SwiftUI/window
    /// update without a fixed sleep.
    @discardableResult
    func waitUntil<T>(timeout: TimeInterval = 5, _ value: () -> T, satisfies predicate: (T) -> Bool) -> T {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var sample = value()
        while !predicate(sample) && Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            sample = value()
        }
        return sample
    }
}
