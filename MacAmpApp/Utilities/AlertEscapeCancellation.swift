import AppKit

@MainActor
final class AlertEscapeCancellation {
    private let window: NSWindow
    private let activate: () -> Void
    private let monitors: LocalEventMonitorRegistration
    private var monitor: Any?
    private var isActive = true

    init(alert: NSAlert, monitors: LocalEventMonitorRegistration) {
        self.window = alert.window
        self.monitors = monitors
        self.activate = { alert.buttons.first?.performClick(nil) }
        monitor = monitors.add(.keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event, in: event.window)
        }
    }

    isolated deinit {
        if let monitor { monitors.remove(monitor) }
    }

    func handle(_ event: NSEvent, in eventWindow: NSWindow?) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard isActive, event.type == .keyDown, event.keyCode == 53,
              modifiers.isEmpty, eventWindow === window else { return event }
        invalidate()
        activate()
        return nil
    }

    func invalidate() {
        isActive = false
        if let monitor {
            self.monitor = nil
            monitors.remove(monitor)
        }
    }
}
