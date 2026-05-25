import SwiftUI

/// Single source of truth for MacAmp's modifier-based keyboard shortcuts.
/// Menu shortcuts in `AppCommands.swift` and tooltip text in main-window
/// views both read from here, so a rebinding lives in exactly one place.
///
/// Plain-key bindings (Z/X/C/V/B, L, R, S, arrows, Option+W/E/G) are
/// dispatched by `WinampHotkeyMonitor` and don't need menu shortcuts.
struct WinampKeyBinding {
    let key: Character
    let modifiers: EventModifiers

    var shortcut: KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(key), modifiers: modifiers)
    }

    /// Mac-conventional rendering: `⌃⌥⇧⌘` then the key, e.g. "⌘⇧O".
    var displayLabel: String {
        var label = ""
        if modifiers.contains(.control) { label += "⌃" }
        if modifiers.contains(.option) { label += "⌥" }
        if modifiers.contains(.shift) { label += "⇧" }
        if modifiers.contains(.command) { label += "⌘" }
        label += String(key).uppercased()
        return label
    }
}

enum WinampKeyBindings {
    static let alwaysOnTop          = WinampKeyBinding(key: "a", modifiers: .command)
    static let doubleSize           = WinampKeyBinding(key: "d", modifiers: .command)
    static let timeMode             = WinampKeyBinding(key: "t", modifiers: .command)
    static let trackInfo            = WinampKeyBinding(key: "i", modifiers: .command)
    static let milkdrop             = WinampKeyBinding(key: "k", modifiers: .command)
    static let openFiles            = WinampKeyBinding(key: "o", modifiers: .command)
    static let preferences          = WinampKeyBinding(key: ",", modifiers: .command)
    static let openOptionsMenu      = WinampKeyBinding(key: "o", modifiers: [.command, .shift])
    static let videoWindow          = WinampKeyBinding(key: "v", modifiers: [.command, .shift])
    static let toggleMainWindow     = WinampKeyBinding(key: "1", modifiers: [.command, .shift])
    static let togglePlaylistWindow = WinampKeyBinding(key: "2", modifiers: [.command, .shift])
    static let toggleEqualizerWindow = WinampKeyBinding(key: "3", modifiers: [.command, .shift])
    static let shadeMainWindow      = WinampKeyBinding(key: "1", modifiers: [.command, .option])
    static let shadePlaylistWindow  = WinampKeyBinding(key: "2", modifiers: [.command, .option])
    static let shadeEqualizerWindow = WinampKeyBinding(key: "3", modifiers: [.command, .option])
}
