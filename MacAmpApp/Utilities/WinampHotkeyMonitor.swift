import AppKit

/// App-level keyDown monitor for the plain-key and `⌥`-letter shortcuts in
/// `WinampKeyBindings.plainKeyBindings` / `optionKeyBindings`, plus arrow
/// seek/volume. Dispatches through `UserActionDispatcher`; returns the
/// event when the (window, modifiers, key) combination falls outside the
/// claim set.
@MainActor
final class WinampHotkeyMonitor {
    private let perform: @MainActor (UserAction) -> Void
    private let primaryWindows: @MainActor () -> Set<NSWindowIdentity>
    private let playlistWindow: @MainActor () -> NSWindow?
    private var monitor: Any?

    private let plainKeyActions: [Character: UserAction]
    private let optionKeyActions: [Character: UserAction]

    init(
        perform: @escaping @MainActor (UserAction) -> Void,
        primaryWindows: @escaping @MainActor () -> Set<NSWindowIdentity>,
        playlistWindow: @escaping @MainActor () -> NSWindow?
    ) {
        self.perform = perform
        self.primaryWindows = primaryWindows
        self.playlistWindow = playlistWindow
        self.plainKeyActions = Dictionary(
            uniqueKeysWithValues: WinampKeyBindings.plainKeyBindings.map { ($0.key, $0.action) }
        )
        self.optionKeyActions = Dictionary(
            uniqueKeysWithValues: WinampKeyBindings.optionKeyBindings.map { ($0.key, $0.action) }
        )
        install()
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, primaryWindows().contains(.init(window)) else { return event }
        if window.firstResponder is NSText { return event }

        let appShortcutModifiers = event.modifierFlags.intersection([.command, .option, .control])

        if appShortcutModifiers == .option {
            return dispatchLetter(event, table: optionKeyActions)
        }
        guard appShortcutModifiers.isEmpty else { return event }

        // ↑/↓ adjust volume, except over the playlist, where they move the
        // cursor. Defer those to the playlist's own monitor so the outcome
        // doesn't depend on keyDown-monitor registration order.
        switch event.keyCode {
        case 123: perform(.seekBy(seconds: -5)); return nil
        case 124: perform(.seekBy(seconds: +5)); return nil
        case 125 where window !== playlistWindow(): perform(.adjustVolume(percent: -1)); return nil
        case 126 where window !== playlistWindow(): perform(.adjustVolume(percent: +1)); return nil
        default:
            break
        }

        return dispatchLetter(event, table: plainKeyActions)
    }

    private func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // `?? event` would collapse the optional chain into a single
            // NSEvent? and replace a legitimate consume (nil) with the original
            // event, defeating the suppression.
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func dispatchLetter(_ event: NSEvent, table: [Character: UserAction]) -> NSEvent? {
        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              let key = chars.first,
              chars.count == 1,
              let action = table[key] else {
            return event
        }
        perform(action)
        return nil
    }
}
