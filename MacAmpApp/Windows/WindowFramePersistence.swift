import AppKit

/// Manages window frame persistence: save/load positions, suppression during programmatic moves.
@MainActor
final class WindowFramePersistence {
    private let registry: WindowRegistry
    private let windowFrameStore: WindowFrameStore
    private let settings: AppSettings
    private var persistenceSuppressionCount = 0
    @MainActor private var persistenceTask: Task<Void, Never>?
    // swiftlint:disable:next weak_delegate
    private(set) var persistenceDelegate: WindowPersistenceDelegate?  // Intentionally strong: NSWindow.delegate is weak

    init(registry: WindowRegistry, settings: AppSettings, windowFrameStore: WindowFrameStore = WindowFrameStore()) {
        self.registry = registry
        self.settings = settings
        self.windowFrameStore = windowFrameStore
        self.persistenceDelegate = WindowPersistenceDelegate(persistence: self)
    }

    // MARK: - Suppression

    func beginSuppressingPersistence() {
        persistenceSuppressionCount += 1
    }

    func endSuppressingPersistence() {
        persistenceSuppressionCount = max(0, persistenceSuppressionCount - 1)
    }

    func performWithoutPersistence(_ work: () -> Void) {
        beginSuppressingPersistence()
        work()
        endSuppressingPersistence()
    }

    // MARK: - Persistence

    func persistAllWindowFrames() {
        registry.forEachWindow { window, kind in
            windowFrameStore.save(frame: window.frame, for: kind)
        }
    }

    func schedulePersistenceFlush() {
        guard persistenceSuppressionCount == 0 else { return }
        persistenceTask?.cancel()
        persistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.persistAllWindowFrames()
        }
    }

    func handleWindowGeometryChange(notification: Notification) {
        guard persistenceSuppressionCount == 0 else { return }
        guard let window = notification.object as? NSWindow else { return }
        guard registry.windowKind(for: window) != nil else { return }
        schedulePersistenceFlush()
    }

    // MARK: - Layout Restoration

    @discardableResult
    func applyPersistedWindowPositions() -> Bool {
        beginSuppressingPersistence()
        defer { endSuppressingPersistence() }

        var applied = false
        let scale: CGFloat = settings.isDoubleSizeMode ? 2 : 1

        applied = restoreMainWindow(scale: scale) || applied
        applied = restoreEQWindow(scale: scale) || applied
        applied = restorePlaylistWindow() || applied
        applied = restoreFullFrame(kind: .video) || applied
        applied = restoreFullFrame(kind: .milkdrop) || applied

        return applied
    }

    private func restoreMainWindow(scale: CGFloat) -> Bool {
        guard let main = registry.mainWindow,
              let stored = windowFrameStore.frame(for: .main) else { return false }
        let newSize = CGSize(width: WinampSizes.main.width * scale, height: WinampSizes.main.height * scale)
        main.setFrame(topLeftAnchoredFrame(stored: stored, newSize: newSize), display: true)
        return true
    }

    private func restoreEQWindow(scale: CGFloat) -> Bool {
        guard let eq = registry.eqWindow,
              let stored = windowFrameStore.frame(for: .equalizer) else { return false }
        let newSize = CGSize(width: WinampSizes.equalizer.width * scale, height: WinampSizes.equalizer.height * scale)
        eq.setFrame(topLeftAnchoredFrame(stored: stored, newSize: newSize), display: true)
        return true
    }

    /// Build a frame whose visual top-left matches the persisted frame's
    /// visual top-left. Persisted state can be from a shaded window (small
    /// height); restoring at that bottom-left with a forced full height would
    /// push the visual top above where the user left it. Subsequent SwiftUI
    /// `[.preferredContentSize]` resizes are top-anchored, so the placed
    /// top-left survives the rest of restoration.
    private func topLeftAnchoredFrame(stored: NSRect, newSize: CGSize) -> NSRect {
        let persistedTopY = stored.origin.y + stored.size.height
        return NSRect(
            x: stored.origin.x,
            y: persistedTopY - newSize.height,
            width: newSize.width,
            height: newSize.height
        )
    }

    private func restorePlaylistWindow() -> Bool {
        guard let playlist = registry.playlistWindow,
              let stored = windowFrameStore.frame(for: .playlist) else { return false }
        let newSize = CGSize(
            width: max(PlaylistWindowSizeState.baseWidth, stored.size.width),
            height: max(
                PlaylistWindowSizeState.baseHeight,
                min(LayoutDefaults.playlistMaxHeight, stored.size.height)
            )
        )
        playlist.setFrame(topLeftAnchoredFrame(stored: stored, newSize: newSize), display: true)
        return true
    }

    /// Restore the full stored frame (origin + size) for windows whose runtime
    /// size comes from a persisted sizeState that matches what was saved.
    /// Restoring only the origin would leave the window at the initial 275×232
    /// BorderlessWindow contentRect; SwiftUI's `onAppear` then top-anchors a
    /// resize to the real pixelSize from the persisted segments, but that
    /// top-anchor pivots off the wrong (initial) height — shifting the visual
    /// top by (storedHeight − 232). Restoring stored.size makes the later
    /// SwiftUI resize a no-op so the top stays where the user left it.
    private func restoreFullFrame(kind: WindowKind) -> Bool {
        guard let window = registry.window(for: kind),
              let stored = windowFrameStore.frame(for: kind) else { return false }
        window.setFrame(stored, display: true)
        return true
    }

    // MARK: - Off-Screen Rescue

    /// Per-window rescue: if `window`'s 22-pt top strip doesn't overlap any
    /// current screen's `visibleFrame`, re-anchor the frame so it lands at the
    /// nearest screen's visible top-left. Called whenever a window is shown so
    /// a persisted frame from a monitor layout that no longer exists is pulled
    /// back into view. A reachable frame is left untouched, so on-screen
    /// positions — and the relative offsets between on-screen windows — survive.
    func ensureReachable(_ window: NSWindow) {
        let frame = window.frame
        guard !isReachable(frame) else { return }
        guard let target = nearestScreen(for: frame)?.visibleFrame else { return }
        var snapped = frame
        snapped.origin = NSPoint(x: target.origin.x, y: target.maxY - frame.height)
        window.setFrame(snapped, display: true)
    }

    private func isReachable(_ frame: NSRect) -> Bool {
        let topStripHeight: CGFloat = 22
        let topStrip = NSRect(
            x: frame.origin.x,
            y: frame.maxY - topStripHeight,
            width: frame.width,
            height: topStripHeight
        )
        return NSScreen.screens.contains { screen in
            let inter = screen.visibleFrame.intersection(topStrip)
            return inter.width >= 30 && inter.height > 0
        }
    }

    private func nearestScreen(for bounds: NSRect) -> NSScreen? {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        return NSScreen.screens.min { lhs, rhs in
            let lc = CGPoint(x: lhs.visibleFrame.midX, y: lhs.visibleFrame.midY)
            let rc = CGPoint(x: rhs.visibleFrame.midX, y: rhs.visibleFrame.midY)
            return hypot(center.x - lc.x, center.y - lc.y) < hypot(center.x - rc.x, center.y - rc.y)
        }
    }

    // MARK: - Constants

    enum LayoutDefaults {
        static let playlistMaxHeight: CGFloat = 900
    }
}

// MARK: - WindowPersistenceDelegate

@MainActor
final class WindowPersistenceDelegate: NSObject, NSWindowDelegate {
    weak var persistence: WindowFramePersistence?

    init(persistence: WindowFramePersistence) {
        self.persistence = persistence
    }

    func windowDidMove(_ notification: Notification) {
        persistence?.handleWindowGeometryChange(notification: notification)
    }

    func windowDidResize(_ notification: Notification) {
        persistence?.handleWindowGeometryChange(notification: notification)
    }
}
