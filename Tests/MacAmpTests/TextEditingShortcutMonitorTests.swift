import Testing
import AppKit
@testable import MacAmp

@MainActor
@Suite("TextEditingShortcutMonitor", .serialized)
struct TextEditingShortcutMonitorTests {

    // MARK: - End-to-end: ⌘A in the Add Internet Radio Station alert

    @Test("⌘A selects the entire URL field in the Add Internet Radio Station alert")
    func cmdA_inAddUrlAlert_selectsAll() throws {
        let alert = NSAlert()
        alert.messageText = "Add Internet Radio Station"
        alert.informativeText = "Enter the stream URL (HTTP or HTTPS):"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "http://stream.example.com/radio.mp3"
        input.usesSingleLineMode = true
        input.lineBreakMode = .byClipping
        input.cell?.wraps = false
        input.cell?.isScrollable = true
        alert.accessoryView = input
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        alert.layout()
        let window = alert.window
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        input.stringValue = "select_me_please"
        _ = window.makeFirstResponder(input)
        let fieldEditor = try #require(window.firstResponder as? NSText)
        fieldEditor.selectedRange = NSRange(location: 0, length: 0)

        let monitor = TextEditingShortcutMonitor()
        let event = try #require(makeKeyDown("a", modifiers: [.command], in: window))
        let consumed = monitor.handle(event)

        #expect(consumed == nil, "monitor must consume ⌘A in a text-editing context")
        #expect(
            fieldEditor.selectedRange.length == input.stringValue.count,
            "⌘A should select all \(input.stringValue.count) chars; got length \(fieldEditor.selectedRange.length)"
        )
    }

    // MARK: - Passes through outside text-editing contexts

    @Test("⌘A in a window with no NSText first responder passes through")
    func cmdA_outsideTextEditing_passesThrough() throws {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let monitor = TextEditingShortcutMonitor()
        let event = try #require(makeKeyDown("a", modifiers: [.command], in: window))
        let consumed = monitor.handle(event)
        #expect(consumed === event)
    }

    @Test("Plain 'a' (no modifiers) in a focused text field passes through")
    func plainA_inTextField_passesThrough() throws {
        let window = makeWindow()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(field)
        defer { window.orderOut(nil) }

        let monitor = TextEditingShortcutMonitor()
        let event = try #require(makeKeyDown("a", modifiers: [], in: window))
        let consumed = monitor.handle(event)
        #expect(consumed === event)
    }

    @Test("⌘⇧A in a focused text field passes through (modifiers must be exactly ⌘)")
    func cmdShiftA_passesThrough() throws {
        let window = makeWindow()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(field)
        defer { window.orderOut(nil) }

        let monitor = TextEditingShortcutMonitor()
        let event = try #require(makeKeyDown("a", modifiers: [.command, .shift], in: window))
        let consumed = monitor.handle(event)
        #expect(consumed === event)
    }

    @Test("⌘B in a focused text field passes through (only ⌘A is claimed)")
    func cmdB_inTextField_passesThrough() throws {
        let window = makeWindow()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(field)
        defer { window.orderOut(nil) }

        let monitor = TextEditingShortcutMonitor()
        let event = try #require(makeKeyDown("b", modifiers: [.command], in: window))
        let consumed = monitor.handle(event)
        #expect(consumed === event)
    }

    // MARK: - Helpers

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

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
}
