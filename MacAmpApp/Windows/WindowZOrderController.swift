import AppKit

/// Keeps MacAmp's borderless windows visually grouped as one app: whenever any
/// MacAmp window becomes key (or the app activates), every other visible
/// MacAmp window is lifted above non-MacAmp windows while preserving its
/// existing relative Z-order. The key window ends up on top.
@MainActor
final class WindowZOrderController {
    private let registry: WindowRegistry

    init(registry: WindowRegistry) {
        self.registry = registry
    }

    /// Lifts all visible MacAmp windows above non-MacAmp windows while
    /// preserving their current relative Z-order. `keyWindow` (or
    /// `NSApp.keyWindow` if nil) is placed on top.
    func bringAllWindowsForward(keyWindow: NSWindow? = nil) {
        let effectiveKey = keyWindow ?? NSApp.keyWindow
        let backToFront = visibleManagedWindowsBackToFront()
        guard !backToFront.isEmpty else { return }

        for window in backToFront where window !== effectiveKey {
            window.orderFront(nil)
        }
        if let effectiveKey, backToFront.contains(where: { $0 === effectiveKey }) {
            effectiveKey.orderFront(nil)
        }
    }

    private func visibleManagedWindowsBackToFront() -> [NSWindow] {
        var managed: [ObjectIdentifier: NSWindow] = [:]
        registry.forEachWindow { window, _ in
            if window.isVisible {
                managed[ObjectIdentifier(window)] = window
            }
        }
        guard !managed.isEmpty else { return [] }

        // NSApp.orderedWindows is front-to-back; reverse to back-to-front.
        let frontToBack = NSApp.orderedWindows.compactMap { managed[ObjectIdentifier($0)] }
        return frontToBack.reversed()
    }
}
