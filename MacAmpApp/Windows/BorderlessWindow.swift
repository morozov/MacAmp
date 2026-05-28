import AppKit

/// Custom NSWindow subclass that allows borderless windows to accept input and become key/main
class BorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Anchor point (screen coords) of the current Ctrl+Cmd cohesive drag, set
    /// on mouseDown and cleared on mouseUp. Non-nil means the next mouseDragged
    /// and mouseUp belong to that drag and must bypass normal hit testing.
    private var cohesiveDragAnchor: NSPoint?

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
    ///
    /// Also intercepts Ctrl+Cmd+leftMouseDown anywhere in the window and
    /// drives the WindowSnapManager cohesive-cluster drag (matching macOS's
    /// system Ctrl+Cmd+drag gesture). Routing through sendEvent — the single
    /// entry point every event passes through — means the gesture works on
    /// every surface (titlebars, buttons, sliders, visualizer) without
    /// per-view plumbing.
    override func sendEvent(_ event: NSEvent) {
        if !isKeyWindow,
           event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
            makeKeyAndOrderFront(nil)
        }

        if handleCohesiveDrag(event) { return }

        super.sendEvent(event)
    }

    /// Returns true when the event has been consumed by the cohesive-drag
    /// pipeline and must not be forwarded to child views.
    ///
    /// Modifiers only gate the initial mouseDown: once a drag is active,
    /// releasing Ctrl/Cmd mid-drag does not abort it, matching native
    /// macOS Ctrl+Cmd+drag behavior.
    private func handleCohesiveDrag(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            guard event.modifierFlags.contains([.control, .command]) else {
                cohesiveDragAnchor = nil
                return false
            }
            guard let kind = WindowSnapManager.shared.kind(for: self) else { return false }
            let anchor = convertPoint(toScreen: event.locationInWindow)
            cohesiveDragAnchor = anchor
            WindowSnapManager.shared.beginCustomDrag(
                kind: kind,
                startPointInScreen: anchor,
                scope: .cohesiveCluster
            )
            return true

        case .leftMouseDragged:
            guard let anchor = cohesiveDragAnchor,
                  let kind = WindowSnapManager.shared.kind(for: self) else { return false }
            let current = convertPoint(toScreen: event.locationInWindow)
            let delta = CGPoint(x: current.x - anchor.x, y: current.y - anchor.y)
            WindowSnapManager.shared.updateCustomDrag(kind: kind, cumulativeDelta: delta)
            return true

        case .leftMouseUp:
            guard cohesiveDragAnchor != nil,
                  let kind = WindowSnapManager.shared.kind(for: self) else { return false }
            cohesiveDragAnchor = nil
            WindowSnapManager.shared.endCustomDrag(kind: kind)
            return true

        default:
            return false
        }
    }
}
