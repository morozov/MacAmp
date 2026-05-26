import AppKit

/// Custom NSWindow subclass that allows borderless windows to accept input and become key/main
class BorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

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
