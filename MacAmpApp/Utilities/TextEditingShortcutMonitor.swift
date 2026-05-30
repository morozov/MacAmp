import AppKit

/// App-level keyDown monitor that delivers ⌘A → Select All to the focused
/// `NSText` field editor inside modal `NSAlert` dialogs (the Add Internet
/// Radio URL field, the Save EQ Preset name field).
///
/// The handler invokes `selectAll(_:)` directly on the field editor. Inside
/// a modal `NSAlert`, `NSApp.sendAction(_:to:from:)` targeting the field
/// editor returns `false` and performs no selection, so the action is sent
/// to the responder itself rather than through application-wide dispatch.
@MainActor
final class TextEditingShortcutMonitor {
    private var monitor: Any?

    init() {
        install()
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods == .command,
              event.charactersIgnoringModifiers?.lowercased() == "a",
              let target = event.window?.firstResponder as? NSText
        else { return event }
        target.selectAll(nil)
        return nil
    }

    private func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // `?? event` would collapse the optional chain into a single
            // NSEvent? and replace a legitimate consume (nil) with the
            // original event, defeating the suppression.
            guard let self else { return event }
            return self.handle(event)
        }
    }
}
