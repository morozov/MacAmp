import AppKit

/// App-level keyDown monitor for Winamp's plain-key shortcuts. The monitor
/// only translates a `NSEvent` into a `UserAction` and forwards it to the
/// shared `UserActionDispatcher` — every action implementation lives in
/// the dispatcher, so the hotkey path can't drift from a button or menu
/// path for the same action.
///
/// Mirrors `packages/webamp/js/hotkeys.ts` for the non-modifier keys:
/// Z/X/C/V/B (prev/play/pause/stop/next), L (open file), R (cycle
/// repeat), S (toggle shuffle), ←/→ (seek ±5s), ↑/↓ (volume ±1%). Plus
/// Webamp's Alt+W/E/G window toggles remapped to Option+W/E/G for
/// Mac-native modifier semantics.
///
/// ⌘-modifier shortcuts (⌘D double-size, ⌘T time mode, ⌘A always-on-top,
/// etc.) live in `AppCommands` so they appear in the menus.
@MainActor
final class WinampHotkeyMonitor {
    private let dispatcher: UserActionDispatcher
    private var monitor: Any?

    private let plainKeyActions: [Character: UserAction]
    private let optionKeyActions: [Character: UserAction]

    init(dispatcher: UserActionDispatcher) {
        self.dispatcher = dispatcher
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

    private func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Cannot use `self?.handle(event) ?? event`: Swift collapses the
            // optional chain into a single `NSEvent?`, so `?? event` replaces
            // a legitimate "consume" (nil) return from `handle` with the
            // original event, defeating the suppression and producing an
            // AppKit `NSBeep()` for keys we already acted on.
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if isEditingText(in: event.window) { return event }

        let appShortcutModifiers = event.modifierFlags.intersection([.command, .option, .control])

        if appShortcutModifiers == .option {
            return dispatchLetter(event, table: optionKeyActions)
        }
        guard appShortcutModifiers.isEmpty else { return event }

        // Arrow keys map to parameterized actions inline — they have no
        // menu rendering, so they don't carry a `WinampKeyBinding`.
        switch event.keyCode {
        case 123: dispatcher.perform(.seekBy(seconds: -5)); return nil
        case 124: dispatcher.perform(.seekBy(seconds: +5)); return nil
        case 125: dispatcher.perform(.adjustVolume(percent: -1)); return nil
        case 126: dispatcher.perform(.adjustVolume(percent: +1)); return nil
        default:
            break
        }

        return dispatchLetter(event, table: plainKeyActions)
    }

    private func dispatchLetter(_ event: NSEvent, table: [Character: UserAction]) -> NSEvent? {
        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              let key = chars.first,
              chars.count == 1,
              let action = table[key] else {
            return event
        }
        dispatcher.perform(action)
        return nil
    }

    private func isEditingText(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder is NSText { return true }
        if responder is NSTextField { return true }
        return false
    }
}
