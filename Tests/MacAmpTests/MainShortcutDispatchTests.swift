import Testing
import AppKit
@testable import MacAmp

@MainActor
@Suite("MainShortcutDispatch")
struct MainShortcutDispatchTests {
    private let primary = MainShortcutDispatch.Context(
        isInPrimaryWindow: true,
        isEditingText: false,
        isInPlaylistWindow: false
    )

    private let playlist = MainShortcutDispatch.Context(
        isInPrimaryWindow: true,
        isEditingText: false,
        isInPlaylistWindow: true
    )

    private let editing = MainShortcutDispatch.Context(
        isInPrimaryWindow: true,
        isEditingText: true,
        isInPlaylistWindow: false
    )

    // MARK: - Invariant 1: secondary windows never claim

    @Test("Secondary window passes every shortcut through")
    func secondaryWindow_neverClaimsAnyBinding() {
        for binding in WinampKeyBindings.menuShortcutBindings {
            let result = MainShortcutDispatch.action(
                forKey: String(binding.key),
                modifiers: binding.modifiers.nsEventFlags,
                context: .secondaryWindow
            )
            #expect(result == nil, "\(binding.displayLabel) leaked from a secondary window")
        }
    }

    // MARK: - Invariant 2: text editing wins

    @Test("Primary window with text editing focus passes every shortcut through")
    func textEditing_neverClaimsAnyBinding() {
        for binding in WinampKeyBindings.menuShortcutBindings {
            let result = MainShortcutDispatch.action(
                forKey: String(binding.key),
                modifiers: binding.modifiers.nsEventFlags,
                context: editing
            )
            #expect(result == nil, "\(binding.displayLabel) leaked from a text-editing responder")
        }
    }

    // MARK: - Invariant 3: playlist owns ⌘A

    @Test("⌘A in playlist passes through (playlist owns Select All)")
    func cmdA_inPlaylist_passesThrough() {
        let result = MainShortcutDispatch.action(
            forKey: "a", modifiers: .command, context: playlist
        )
        #expect(result == nil)
    }

    @Test("Non-⌘A bindings still claim in playlist")
    func nonCmdA_inPlaylist_stillClaims() {
        let nonCmdA = WinampKeyBindings.menuShortcutBindings.filter { !($0.key == "a" && $0.modifiers == .command) }
        for binding in nonCmdA {
            let result = MainShortcutDispatch.action(
                forKey: String(binding.key),
                modifiers: binding.modifiers.nsEventFlags,
                context: playlist
            )
            #expect(result == binding.action, "\(binding.displayLabel) failed to dispatch from playlist")
        }
    }

    // MARK: - Affirmative dispatch: every binding round-trips in a clean primary context

    @Test("Every menuShortcutBinding dispatches in a clean primary context")
    func everyBinding_dispatchesInPrimary() {
        for binding in WinampKeyBindings.menuShortcutBindings {
            let result = MainShortcutDispatch.action(
                forKey: String(binding.key),
                modifiers: binding.modifiers.nsEventFlags,
                context: primary
            )
            #expect(result == binding.action, "\(binding.displayLabel) didn't dispatch its action")
        }
    }

    // MARK: - Standard pasteboard shortcuts are never claimed

    @Test("Pasteboard shortcuts (⌘C/V/X/Z/⇧Z/F) pass through in every context")
    func pasteboardShortcuts_neverClaimed() {
        let pasteboard: [(String, NSEvent.ModifierFlags)] = [
            ("c", .command),
            ("v", .command),
            ("x", .command),
            ("z", .command),
            ("z", [.command, .shift]),
            ("v", [.command, .option, .shift]),
            ("f", .command),
        ]
        let contexts: [MainShortcutDispatch.Context] = [primary, playlist, editing, .secondaryWindow]
        for (key, mods) in pasteboard {
            for ctx in contexts {
                let result = MainShortcutDispatch.action(forKey: key, modifiers: mods, context: ctx)
                #expect(result == nil, "⌘\(key.uppercased()) claimed in \(ctx)")
            }
        }
    }

    // MARK: - Plain transport letters never reach this dispatcher

    @Test("Plain transport letters (Z/X/C/V/B/L/R/S) pass through")
    func plainLetters_passThrough() {
        for key in ["z", "x", "c", "v", "b", "l", "r", "s"] {
            let result = MainShortcutDispatch.action(
                forKey: key, modifiers: [], context: primary
            )
            #expect(result == nil, "plain '\(key)' must not be claimed by the menu dispatcher")
        }
    }

    // MARK: - Internal table consistency

    @Test("No two menu shortcut bindings share the same (key, modifiers)")
    func noInternalCollisions() {
        var seen: [String: WinampKeyBinding] = [:]
        for binding in WinampKeyBindings.menuShortcutBindings {
            let id = "\(String(binding.key).lowercased())+\(binding.modifiers.nsEventFlags.rawValue)"
            if let prior = seen[id] {
                Issue.record("Collision on \(binding.displayLabel): \(prior.action) and \(binding.action)")
            }
            seen[id] = binding
        }
    }

    @Test("Menu shortcuts do not overlap standard pasteboard shortcuts")
    func noPasteboardOverlap() {
        let forbidden: Set<String> = [
            "c+\(NSEvent.ModifierFlags.command.rawValue)",
            "v+\(NSEvent.ModifierFlags.command.rawValue)",
            "x+\(NSEvent.ModifierFlags.command.rawValue)",
            "z+\(NSEvent.ModifierFlags.command.rawValue)",
        ]
        for binding in WinampKeyBindings.menuShortcutBindings {
            let id = "\(String(binding.key).lowercased())+\(binding.modifiers.nsEventFlags.rawValue)"
            #expect(!forbidden.contains(id), "binding \(binding.displayLabel) claims a standard pasteboard shortcut")
        }
    }
}
