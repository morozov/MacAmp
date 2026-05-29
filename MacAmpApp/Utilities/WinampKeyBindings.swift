import SwiftUI

/// Single source of truth for every keyboard shortcut in the app — both
/// the ⌘-modifier menu shortcuts surfaced by `AppCommands` and the plain
/// Winamp hotkeys (Z/X/C/V/B, L, R, S, Option+W/E/G) dispatched by
/// `WinampHotkeyMonitor`. Each binding carries the `UserAction` it
/// triggers, so a rebinding affects every dispatch surface uniformly and
/// the shortcut and its underlying behavior live in one place.
///
/// Arrow-key shortcuts (←/→ seek, ↑/↓ volume) aren't expressed here —
/// SwiftUI's `KeyboardShortcut` represents them via dedicated
/// `KeyEquivalent` values, and they have no menu rendering — so the
/// hotkey monitor maps their `NSEvent.keyCode` directly to actions.
struct WinampKeyBinding {
    let key: Character
    let modifiers: EventModifiers
    let action: UserAction

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
    // MARK: ⌘-modifier menu shortcuts

    static let alwaysOnTop          = WinampKeyBinding(key: "a", modifiers: .command,              action: .toggleAlwaysOnTop)
    static let doubleSize           = WinampKeyBinding(key: "d", modifiers: .command,              action: .toggleDoubleSize)
    static let timeMode             = WinampKeyBinding(key: "t", modifiers: .command,              action: .toggleTimeDisplayMode)
    static let trackInfo            = WinampKeyBinding(key: "i", modifiers: .command,              action: .showTrackInfo)
    static let milkdrop             = WinampKeyBinding(key: "k", modifiers: .command,              action: .toggleMilkdropWindow)
    static let openFiles            = WinampKeyBinding(key: "o", modifiers: .command,              action: .openFiles)
    static let preferences          = WinampKeyBinding(key: ",", modifiers: .command,              action: .openPreferences)
    static let openOptionsMenu      = WinampKeyBinding(key: "o", modifiers: [.command, .shift],    action: .showOptionsMenu)
    static let videoWindow          = WinampKeyBinding(key: "v", modifiers: [.command, .shift],    action: .toggleVideoWindow)
    static let toggleMainWindow     = WinampKeyBinding(key: "1", modifiers: [.command, .shift],    action: .toggleMainWindow)
    static let togglePlaylistWindow = WinampKeyBinding(key: "2", modifiers: [.command, .shift],    action: .togglePlaylistWindow)
    static let toggleEqualizerWindow = WinampKeyBinding(key: "3", modifiers: [.command, .shift],   action: .toggleEqualizerWindow)
    static let shadeMainWindow      = WinampKeyBinding(key: "1", modifiers: [.command, .option],   action: .shadeMainWindow)
    static let shadePlaylistWindow  = WinampKeyBinding(key: "2", modifiers: [.command, .option],   action: .shadePlaylistWindow)
    static let shadeEqualizerWindow = WinampKeyBinding(key: "3", modifiers: [.command, .option],   action: .shadeEqualizerWindow)

    // MARK: Plain-key Winamp hotkeys (no modifier)

    static let previousTrackHotkey   = WinampKeyBinding(key: "z", modifiers: [], action: .previousTrack)
    static let startPlaybackHotkey   = WinampKeyBinding(key: "x", modifiers: [], action: .startPlayback)
    static let togglePlayPauseHotkey = WinampKeyBinding(key: "c", modifiers: [], action: .togglePlayPause)
    static let stopHotkey            = WinampKeyBinding(key: "v", modifiers: [], action: .stop)
    static let nextTrackHotkey       = WinampKeyBinding(key: "b", modifiers: [], action: .nextTrack)
    static let openFilesHotkey       = WinampKeyBinding(key: "l", modifiers: [], action: .openFiles)
    static let cycleRepeatHotkey     = WinampKeyBinding(key: "r", modifiers: [], action: .cycleRepeatMode)
    static let toggleShuffleHotkey   = WinampKeyBinding(key: "s", modifiers: [], action: .toggleShuffle)

    // MARK: Option+letter window toggles (Webamp's Alt+W/E/G remapped Mac-style)

    static let toggleMainWindowAlt      = WinampKeyBinding(key: "w", modifiers: .option, action: .toggleMainWindow)
    static let togglePlaylistWindowAlt  = WinampKeyBinding(key: "e", modifiers: .option, action: .togglePlaylistWindow)
    static let toggleEqualizerWindowAlt = WinampKeyBinding(key: "g", modifiers: .option, action: .toggleEqualizerWindow)

    // MARK: Plain-key tables consumed by WinampHotkeyMonitor

    /// Plain (no-modifier) letter shortcuts, looked up by `event.charactersIgnoringModifiers`.
    static let plainKeyBindings: [WinampKeyBinding] = [
        previousTrackHotkey, startPlaybackHotkey, togglePlayPauseHotkey,
        stopHotkey, nextTrackHotkey, openFilesHotkey,
        cycleRepeatHotkey, toggleShuffleHotkey
    ]

    /// Option+letter shortcuts, looked up by `event.charactersIgnoringModifiers`
    /// when the modifier set is exactly Option.
    static let optionKeyBindings: [WinampKeyBinding] = [
        toggleMainWindowAlt, togglePlaylistWindowAlt, toggleEqualizerWindowAlt
    ]
}
