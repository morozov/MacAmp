import AppKit

/// App-level keyDown monitor that dispatches the shortcuts in
/// `WinampKeyBindings.menuShortcutBindings` through `UserActionDispatcher`.
/// Returns the event unchanged when `MainShortcutDispatch` declines to claim
/// it, so standard AppKit handling proceeds.
@MainActor
final class MainShortcutMonitor {
    private let perform: @MainActor (UserAction) -> Void
    private let primaryWindows: @MainActor () -> Set<NSWindowIdentity>
    private let playlistWindow: @MainActor () -> NSWindow?
    private var monitor: Any?

    init(
        perform: @escaping @MainActor (UserAction) -> Void,
        primaryWindows: @escaping @MainActor () -> Set<NSWindowIdentity>,
        playlistWindow: @escaping @MainActor () -> NSWindow?
    ) {
        self.perform = perform
        self.primaryWindows = primaryWindows
        self.playlistWindow = playlistWindow
        install()
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        guard let chars = event.charactersIgnoringModifiers else { return event }
        let window = event.window
        let context = MainShortcutDispatch.Context(
            isInPrimaryWindow: window.map { primaryWindows().contains(.init($0)) } ?? false,
            isEditingText: window?.firstResponder is NSText,
            isInPlaylistWindow: window != nil && window === playlistWindow()
        )
        guard let action = MainShortcutDispatch.action(
            forKey: chars,
            modifiers: event.modifierFlags,
            context: context
        ) else {
            return event
        }
        perform(action)
        return nil
    }

    private func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // `?? event` would collapse the optional chain into one NSEvent? and
            // substitute the original event whenever `handle` returns nil,
            // defeating consumption.
            guard let self else { return event }
            return self.handle(event)
        }
    }
}

/// Identity wrapper so a `Set<NSWindow>` keyed on reference identity is
/// expressible in pure Swift without leaking AppKit's reference-equality
/// semantics across the API.
struct NSWindowIdentity: Hashable, Sendable {
    private let id: ObjectIdentifier
    init(_ window: NSWindow) { self.id = ObjectIdentifier(window) }
}
