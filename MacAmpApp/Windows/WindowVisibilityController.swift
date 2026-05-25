import AppKit
import Observation

/// Controls show/hide/toggle for all MacAmp windows and tracks observable visibility state.
@MainActor
@Observable
final class WindowVisibilityController {
    private let registry: WindowRegistry
    private let settings: AppSettings

    var isEQWindowVisible: Bool
    var isPlaylistWindowVisible: Bool

    init(registry: WindowRegistry, settings: AppSettings) {
        self.registry = registry
        self.settings = settings
        // Seed from persisted settings so the first SwiftUI body evaluation
        // (during makeKeyAndOrderFront in showAllWindows) reads the actual
        // restored visibility, not the transient `false` it would see before
        // showAllWindows flips the flags.
        self.isEQWindowVisible = settings.showEqualizerWindow
        self.isPlaylistWindowVisible = settings.showPlaylistWindow
    }

    // MARK: - Key Window Actions

    /// Hide the entire app — Winamp's minimize-the-player semantics. macOS
    /// keeps the app icon in the Dock; clicking it (or Cmd-Tab back) sends
    /// `unhide(_:)`, which re-shows exactly the windows that were visible.
    ///
    /// Per-window `NSWindow.miniaturize(_:)` would put each window in the
    /// Dock as its own tile — borderless windows lose their click-to-restore
    /// affordance, and the user can end up with main minimized while EQ /
    /// playlist still float, which contradicts Winamp's "all sub-windows
    /// move as a group" model.
    func hideApp() {
        NSApp.hide(nil)
    }

    // MARK: - EQ Window

    func showEQWindow(makeKey: Bool = false) {
        if makeKey {
            registry.eqWindow?.makeKeyAndOrderFront(nil)
        } else {
            registry.eqWindow?.orderFront(nil)
        }
        isEQWindowVisible = true
        settings.showEqualizerWindow = true
    }

    func hideEQWindow() {
        registry.eqWindow?.orderOut(nil)
        isEQWindowVisible = false
        settings.showEqualizerWindow = false
    }

    func toggleEQWindowVisibility() -> Bool {
        guard let eq = registry.eqWindow else { return false }
        if eq.isVisible {
            eq.orderOut(nil)
            isEQWindowVisible = false
            settings.showEqualizerWindow = false
            return false
        } else {
            eq.orderFront(nil)
            isEQWindowVisible = true
            settings.showEqualizerWindow = true
            return true
        }
    }

    var isEQWindowCurrentlyVisible: Bool {
        registry.eqWindow?.isVisible ?? false
    }

    // MARK: - Playlist Window

    func showPlaylistWindow(makeKey: Bool = false) {
        if makeKey {
            registry.playlistWindow?.makeKeyAndOrderFront(nil)
        } else {
            registry.playlistWindow?.orderFront(nil)
        }
        isPlaylistWindowVisible = true
        settings.showPlaylistWindow = true
    }

    func hidePlaylistWindow() {
        registry.playlistWindow?.orderOut(nil)
        isPlaylistWindowVisible = false
        settings.showPlaylistWindow = false
    }

    func togglePlaylistWindowVisibility() -> Bool {
        guard let playlist = registry.playlistWindow else { return false }
        if playlist.isVisible {
            playlist.orderOut(nil)
            isPlaylistWindowVisible = false
            settings.showPlaylistWindow = false
            return false
        } else {
            playlist.orderFront(nil)
            isPlaylistWindowVisible = true
            settings.showPlaylistWindow = true
            return true
        }
    }

    var isPlaylistWindowCurrentlyVisible: Bool {
        registry.playlistWindow?.isVisible ?? false
    }

    // MARK: - Menu Command Integration

    func showMain() { registry.mainWindow?.makeKeyAndOrderFront(nil) }
    func hideMain() { registry.mainWindow?.orderOut(nil) }

    func showVideo() {
        AppLog.debug(.window, "showVideo() called")
        registry.videoWindow?.makeKeyAndOrderFront(nil)
    }

    func hideVideo() {
        AppLog.debug(.window, "hideVideo() called")
        registry.videoWindow?.orderOut(nil)
    }

    func showMilkdrop() {
        AppLog.debug(.window, "showMilkdrop() called, window exists: \(registry.milkdropWindow != nil)")
        registry.milkdropWindow?.makeKeyAndOrderFront(nil)
        AppLog.debug(.window, "milkdropWindow.isVisible: \(registry.milkdropWindow?.isVisible ?? false)")
    }

    func hideMilkdrop() {
        AppLog.debug(.window, "hideMilkdrop() called")
        registry.milkdropWindow?.orderOut(nil)
    }

    // MARK: - Batch Operations

    func showAllWindows() {
        registry.mainWindow?.makeKeyAndOrderFront(nil)

        if settings.showPlaylistWindow {
            registry.playlistWindow?.orderFront(nil)
            isPlaylistWindowVisible = true
        }
        if settings.showEqualizerWindow {
            registry.eqWindow?.orderFront(nil)
            isEQWindowVisible = true
        }
        if settings.showVideoWindow {
            registry.videoWindow?.orderFront(nil)
        }
        if settings.showMilkdropWindow {
            registry.milkdropWindow?.orderFront(nil)
        }

        focusAllWindows()
    }

    func focusAllWindows() {
        [registry.mainWindow, registry.eqWindow, registry.playlistWindow,
         registry.videoWindow, registry.milkdropWindow].forEach { window in
            if let contentView = window?.contentView {
                window?.makeFirstResponder(contentView)
            }
        }
    }
}
