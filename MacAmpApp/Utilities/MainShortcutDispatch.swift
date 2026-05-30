import AppKit

/// Resolves a key event to the `UserAction` MacAmp should fire, or `nil` to
/// leave the event for AppKit's standard handling.
///
/// Returns `nil` unless `context.isInPrimaryWindow` is true, the key event
/// is not text editing in that window, and the (key, modifiers) pair is
/// listed in `WinampKeyBindings.menuShortcutBindings`. ⌘A while
/// `context.isInPlaylistWindow` returns `nil` because the playlist owns
/// Select All directly.
@MainActor
enum MainShortcutDispatch {
    struct Context: Sendable, Hashable {
        var isInPrimaryWindow: Bool
        var isEditingText: Bool
        var isInPlaylistWindow: Bool

        static let secondaryWindow = Context(
            isInPrimaryWindow: false,
            isEditingText: false,
            isInPlaylistWindow: false
        )
    }

    static func action(
        forKey rawKey: String,
        modifiers: NSEvent.ModifierFlags,
        context: Context
    ) -> UserAction? {
        guard context.isInPrimaryWindow else { return nil }
        if context.isEditingText { return nil }
        let key = rawKey.lowercased()
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        guard !mods.isEmpty else { return nil }
        if context.isInPlaylistWindow, key == "a", mods == .command { return nil }
        return WinampKeyBindings.menuShortcutBindings.first { binding in
            String(binding.key).lowercased() == key && binding.modifiers.nsEventFlags == mods
        }?.action
    }
}
