import Testing
import AppKit
@testable import MacAmp

@MainActor
@Suite("MainShortcutMonitor")
struct MainShortcutMonitorTests {
    // MARK: - First-responder fixture (tier 2)
    //
    // `MainShortcutDispatch` reads `Context.isEditingText`, and the monitor
    // builds that from `window.firstResponder is NSText`. Pin the AppKit
    // contract that `NSTextField`'s field editor IS an `NSText` subclass
    // during editing, so the monitor's check is reliable.

    @Test("Focused NSTextField yields an NSText first responder")
    func focusedTextField_isNSText() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        window.contentView?.addSubview(field)
        let success = window.makeFirstResponder(field)
        #expect(success)
        #expect(window.firstResponder is NSText)
    }

    @Test("Window with no text focus has a non-NSText first responder")
    func emptyWindow_firstResponderIsNotNSText() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        #expect((window.firstResponder is NSText) == false)
    }

    // MARK: - Synthetic NSEvent through handle (tier 3)
    //
    // Exercise the monitor's event-to-Context wiring with a recording
    // dispatcher and synthetic events sent against real NSWindow objects.

    @Test("Event from a primary window with no text focus dispatches")
    func primaryWindow_dispatches() throws {
        let context = try TestContext(windowFlavor: .primary)
        let event = try #require(makeKeyDown("a", modifiers: [.command], in: context.targetWindow))
        let consumed = context.monitor.handle(event)
        #expect(consumed == nil)
        #expect(context.dispatcher.performed == [.toggleAlwaysOnTop])
    }

    @Test("Event from a secondary window passes through unconditionally")
    func secondaryWindow_passesThrough() throws {
        let context = try TestContext(windowFlavor: .secondary)
        let event = try #require(makeKeyDown("a", modifiers: [.command], in: context.targetWindow))
        let consumed = context.monitor.handle(event)
        #expect(consumed === event)
        #expect(context.dispatcher.performed.isEmpty)
    }

    @Test("Event from a primary window with text focus passes through")
    func primaryWindow_withTextFocus_passesThrough() throws {
        let context = try TestContext(windowFlavor: .primaryEditing)
        let event = try #require(makeKeyDown("a", modifiers: [.command], in: context.targetWindow))
        let consumed = context.monitor.handle(event)
        #expect(consumed === event)
        #expect(context.dispatcher.performed.isEmpty)
    }

    @Test("⌘A in the playlist window passes through")
    func cmdA_inPlaylist_passesThrough() throws {
        let context = try TestContext(windowFlavor: .playlist)
        let event = try #require(makeKeyDown("a", modifiers: [.command], in: context.targetWindow))
        let consumed = context.monitor.handle(event)
        #expect(consumed === event)
        #expect(context.dispatcher.performed.isEmpty)
    }

    @Test("⌘D in the playlist window still dispatches (only ⌘A is playlist-owned)")
    func cmdD_inPlaylist_stillDispatches() throws {
        let context = try TestContext(windowFlavor: .playlist)
        let event = try #require(makeKeyDown("d", modifiers: [.command], in: context.targetWindow))
        let consumed = context.monitor.handle(event)
        #expect(consumed == nil)
        #expect(context.dispatcher.performed == [.toggleDoubleSize])
    }

    @Test("Event with no window passes through")
    func nilWindow_passesThrough() throws {
        let context = try TestContext(windowFlavor: .primary)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))
        let consumed = context.monitor.handle(event)
        #expect(consumed === event)
        #expect(context.dispatcher.performed.isEmpty)
    }
}

// MARK: - Test scaffolding

@MainActor
private final class Recorder {
    var performed: [UserAction] = []
    func perform(_ action: UserAction) { performed.append(action) }
}

@MainActor
private struct TestContext {
    let monitor: MainShortcutMonitor
    let recorder: Recorder
    let targetWindow: NSWindow

    enum WindowFlavor {
        case primary
        case primaryEditing
        case playlist
        case secondary
    }

    var dispatcher: Recorder { recorder }

    init(windowFlavor: WindowFlavor) throws {
        let target = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        if case .primaryEditing = windowFlavor {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            target.contentView?.addSubview(field)
            _ = target.makeFirstResponder(field)
        }

        let primaryIdentities: Set<NSWindowIdentity>
        let playlistRef: NSWindow?
        switch windowFlavor {
        case .primary, .primaryEditing:
            primaryIdentities = [.init(target)]
            playlistRef = nil
        case .playlist:
            primaryIdentities = [.init(target)]
            playlistRef = target
        case .secondary:
            primaryIdentities = []
            playlistRef = nil
        }

        let recorder = Recorder()
        self.recorder = recorder
        self.targetWindow = target
        self.monitor = MainShortcutMonitor(
            perform: { action in recorder.perform(action) },
            primaryWindows: { primaryIdentities },
            playlistWindow: { playlistRef }
        )
    }
}

@MainActor
private func makeKeyDown(_ key: String, modifiers: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: key,
        charactersIgnoringModifiers: key,
        isARepeat: false,
        keyCode: 0
    )
}
