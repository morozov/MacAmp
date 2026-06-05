import AppKit

/// Moves the ⌘A key equivalent from the Edit ▸ Select All menu item to the
/// Options ▸ Always On Top item so the latter displays its badge.
///
/// The menu awards a key equivalent to a single owner; SwiftUI gives ⌘A to
/// Select All, leaving Always On Top with none. `TextEditingShortcutMonitor`
/// and `MainShortcutMonitor` deliver ⌘A's behavior in text fields and player
/// windows before the menu is consulted, so Select All's menu key equivalent
/// is not the input mechanism and can be released to free the badge slot.
@MainActor
enum AlwaysOnTopBadge {
    static func apply() {
        guard let mainMenu = NSApp.mainMenu else { return }

        var selectAll: NSMenuItem?
        var alwaysOnTop: NSMenuItem?
        for top in mainMenu.items {
            guard let submenu = top.submenu else { continue }
            for item in submenu.items {
                if item.action == #selector(NSText.selectAll(_:)) {
                    selectAll = item
                }
                if item.title == "Always On Top" {
                    alwaysOnTop = item
                }
            }
        }

        if selectAll?.keyEquivalent == "a" {
            selectAll?.keyEquivalent = ""
        }
        if alwaysOnTop?.keyEquivalent != "a" {
            alwaysOnTop?.keyEquivalent = "a"
            alwaysOnTop?.keyEquivalentModifierMask = .command
        }
    }
}
