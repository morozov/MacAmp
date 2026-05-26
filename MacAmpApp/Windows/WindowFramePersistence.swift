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
        applied = restoreOriginOnly(kind: .video) || applied
        applied = restoreOriginOnly(kind: .milkdrop) || applied

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

    private func restoreOriginOnly(kind: WindowKind) -> Bool {
        guard let window = registry.window(for: kind),
              let stored = windowFrameStore.frame(for: kind) else { return false }
        var frame = window.frame
        frame.origin = stored.origin
        window.setFrame(frame, display: true)
        return true
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
