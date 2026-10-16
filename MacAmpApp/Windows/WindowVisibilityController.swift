import AppKit
import Observation

/// Controls show/hide/toggle for all MacAmp windows and tracks observable visibility state.
@MainActor
@Observable
final class WindowVisibilityController {
    private let registry: WindowRegistry
    private let settings: AppSettings

    /// Persisted in AppSettings so the open/closed state survives relaunch.
    var isEQWindowVisible: Bool {
        get { settings.showEqualizerWindow }
        set { settings.showEqualizerWindow = newValue }
    }
    var isPlaylistWindowVisible: Bool {
        get { settings.showPlaylistWindow }
        set { settings.showPlaylistWindow = newValue }
    }
    var isMainWindowVisible: Bool = true

    init(registry: WindowRegistry, settings: AppSettings) {
        self.registry = registry
        self.settings = settings
    }

    // MARK: - EQ Window

    func showEQWindow(makeKey: Bool = false) {
        isEQWindowVisible = true
        guard !deferWhileMinimized(.equalizer) else { return }
        if makeKey {
            registry.eqWindow?.makeKeyAndOrderFront(nil)
        } else {
            registry.eqWindow?.orderFront(nil)
        }
        onWindowShown?()
    }

    func hideEQWindow() {
        registry.eqWindow?.orderOut(nil)
        isEQWindowVisible = false
    }

    func toggleEQWindowVisibility() -> Bool {
        guard let eq = registry.eqWindow else { return false }
        let show = isGroupMinimized ? !isEQWindowVisible : !eq.isVisible
        if show { showEQWindow() } else { hideEQWindow() }
        return show
    }

    var isEQWindowCurrentlyVisible: Bool {
        registry.eqWindow?.isVisible ?? false
    }

    // MARK: - Playlist Window

    func showPlaylistWindow(makeKey: Bool = false) {
        isPlaylistWindowVisible = true
        guard !deferWhileMinimized(.playlist) else { return }
        if makeKey {
            registry.playlistWindow?.makeKeyAndOrderFront(nil)
        } else {
            registry.playlistWindow?.orderFront(nil)
        }
        onWindowShown?()
    }

    func hidePlaylistWindow() {
        registry.playlistWindow?.orderOut(nil)
        isPlaylistWindowVisible = false
    }

    func togglePlaylistWindowVisibility() -> Bool {
        guard let playlist = registry.playlistWindow else { return false }
        let show = isGroupMinimized ? !isPlaylistWindowVisible : !playlist.isVisible
        if show { showPlaylistWindow() } else { hidePlaylistWindow() }
        return show
    }

    var isPlaylistWindowCurrentlyVisible: Bool {
        registry.playlistWindow?.isVisible ?? false
    }

    // MARK: - Menu Command Integration

    func showMain() {
        guard let main = registry.mainWindow else { return }
        if let proxy {
            proxy.deminiaturize(nil)
        } else {
            main.makeKeyAndOrderFront(nil)
            onWindowShown?()
        }
        isMainWindowVisible = true
    }

    func hideMain() {
        registry.mainWindow?.orderOut(nil)
        isMainWindowVisible = false
    }

    func toggleMain() {
        if isMainWindowVisible { hideMain() } else { showMain() }
    }

    func showVideo() {
        AppLog.debug(.window, "showVideo() called")
        guard !deferWhileMinimized(.video) else { return }
        registry.videoWindow?.makeKeyAndOrderFront(nil)
        onWindowShown?()
    }

    func hideVideo() {
        AppLog.debug(.window, "hideVideo() called")
        registry.videoWindow?.orderOut(nil)
    }

    func showMilkdrop() {
        AppLog.debug(.window, "showMilkdrop() called, window exists: \(registry.milkdropWindow != nil)")
        guard !deferWhileMinimized(.milkdrop) else { return }
        registry.milkdropWindow?.makeKeyAndOrderFront(nil)
        onWindowShown?()
        AppLog.debug(.window, "milkdropWindow.isVisible: \(registry.milkdropWindow?.isVisible ?? false)")
    }

    func hideMilkdrop() {
        AppLog.debug(.window, "hideMilkdrop() called")
        registry.milkdropWindow?.orderOut(nil)
    }

    // MARK: - Group Minimize

    /// Windows the group minimize hid, front to back; they come back if still open in settings.
    @ObservationIgnored private var minimizedWith: [WindowKind] = []
    /// In the Dock while the group is minimized.
    @ObservationIgnored private var proxy: NSWindow?
    @ObservationIgnored private var isCapturingGroup = false
    @ObservationIgnored private var deminiaturizeToken: NotificationCenter.ObservationToken?
    /// Runs after the group returns from the Dock.
    @ObservationIgnored var onGroupRestored: (@MainActor () -> Void)?
    /// Runs after a window is shown, so one persisted on a missing display is pulled back on-screen.
    @ObservationIgnored var onWindowShown: (@MainActor () -> Void)?

    var canMinimizeGroup: Bool {
        guard let main = registry.mainWindow else { return false }
        return main.isVisible && proxy == nil && !isCapturingGroup
    }

    private var isGroupMinimized: Bool { proxy != nil }

    /// Winamp minimize: one Dock tile for the whole group; the windows hide without changing their open state.
    /// A group that does not fit on one screen hides the app instead, since one proxy window cannot span displays.
    func minimizeGroup() {
        guard canMinimizeGroup else { return }
        let group = visibleGroup()
        guard NSScreen.screens.contains(where: { screen in group.allSatisfy { screen.frame.contains($0.window.frame) } }) else {
            NSApp.hide(nil)
            return
        }
        let frames = group.map(\.window.frame)
        isCapturingGroup = true
        Task {
            let proxy = await GroupMinimizeProxy.make(for: group.map(\.window))
            isCapturingGroup = false
            // The capture awaits WebKit; the picture is stale if the group changed meanwhile.
            guard canMinimizeGroup, visibleGroup().map(\.window) == group.map(\.window),
                  group.map(\.window.frame) == frames else { return }
            guard let proxy else {
                NSApp.hide(nil)
                return
            }
            hand(group, to: proxy)
        }
    }

    func stop() {
        if let deminiaturizeToken { NotificationCenter.default.removeObserver(deminiaturizeToken) }
        deminiaturizeToken = nil
    }

    /// The visible MacAmp windows, front to back.
    private func visibleGroup() -> [(window: NSWindow, kind: WindowKind)] {
        let numbers = NSWindow.windowNumbers(options: []) ?? []
        return numbers.compactMap { number in
            guard let window = NSApp.window(withWindowNumber: number.intValue), window.isVisible,
                  let kind = registry.windowKind(for: window) else { return nil }
            return (window, kind)
        }
    }

    /// The proxy shows the same pixels as the group, so swapping one for the other is invisible.
    private func hand(_ group: [(window: NSWindow, kind: WindowKind)], to proxy: NSWindow) {
        guard let front = group.first?.window else { return }
        proxy.order(.above, relativeTo: front.windowNumber)
        // Commit the proxy's pixels before the group leaves, or the screen shows neither for a frame.
        proxy.displayIfNeeded()
        CATransaction.flush()
        for (window, kind) in group {
            minimizedWith.append(kind)
            window.orderOut(nil)
        }
        isMainWindowVisible = false
        self.proxy = proxy
        deminiaturizeToken = NotificationCenter.default.addObserver(of: proxy, for: .didDeminiaturize) { [weak self] _ in
            self?.restoreMinimizedGroup()
        }
        proxy.miniaturize(nil)
    }

    /// AppKit posts `didDeminiaturize` once the Dock has finished animating the proxy back to its frame.
    private func restoreMinimizedGroup() {
        guard let proxy else { return }
        var above = proxy.windowNumber
        for kind in minimizedWith where isOpen(kind) {
            guard let window = registry.window(for: kind) else { continue }
            window.order(.below, relativeTo: above)
            above = window.windowNumber
        }
        proxy.hasShadow = false
        registry.mainWindow?.makeKey()
        // A restore through orderFront(_:) orders the proxy in again after this handler returns.
        DispatchQueue.main.async { proxy.orderOut(nil) }
        stop()
        self.proxy = nil
        minimizedWith = []
        isMainWindowVisible = true
        onGroupRestored?()
    }

    private func isOpen(_ kind: WindowKind) -> Bool {
        switch kind {
        case .main: true
        case .equalizer: settings.showEqualizerWindow
        case .playlist: settings.showPlaylistWindow
        case .video: settings.showVideoWindow
        case .milkdrop: settings.showMilkdropWindow
        }
    }

    /// While minimized, a window turned on waits to come back with Main.
    private func deferWhileMinimized(_ kind: WindowKind) -> Bool {
        guard isGroupMinimized else { return false }
        if !minimizedWith.contains(kind) { minimizedWith.append(kind) }
        return true
    }

    // MARK: - Batch Operations

    func showAllWindows() {
        registry.mainWindow?.makeKeyAndOrderFront(nil)
        isMainWindowVisible = true
        if settings.showEqualizerWindow {
            registry.eqWindow?.orderFront(nil)
        }
        if settings.showPlaylistWindow {
            registry.playlistWindow?.orderFront(nil)
        }

        if settings.showVideoWindow {
            registry.videoWindow?.orderFront(nil)
        }
        if settings.showMilkdropWindow {
            registry.milkdropWindow?.orderFront(nil)
        }

        onWindowShown?()
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
