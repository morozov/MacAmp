import AppKit

/// Custom NSWindow subclass that allows borderless windows to accept input and become key/main
class BorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Window › Minimize (Cmd+M) minimizes the whole player from any MacAmp window.
    override func performMiniaturize(_ sender: Any?) {
        WindowCoordinator.shared?.minimizeApp()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(performMiniaturize(_:))
            ? WindowCoordinator.shared?.canMinimizeApp ?? false
            : super.validateUserInterfaceItem(item)
    }

    /// Deliver first-mouse clicks on inactive windows as if the window were
    /// already key. macOS normally swallows the click that activates an
    /// inactive window unless the deepest hit-tested view returns true from
    /// `acceptsFirstMouse(for:)`. SwiftUI's gesture system installs internal
    /// NSViews we cannot subclass and they always return false — so dragging
    /// a slider on an inactive MacAmp window needs two clicks (one to
    /// activate, one to drag).
    ///
    /// Override sendEvent: when a mouse-down arrives at a non-key window,
    /// promote the window to key first, then forward the event normally.
    /// Subsequent drag/up events flow through the usual path since the
    /// window is now key.
    override func sendEvent(_ event: NSEvent) {
        if !isKeyWindow,
           event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
            makeKeyAndOrderFront(nil)
        }
        super.sendEvent(event)
    }
}
