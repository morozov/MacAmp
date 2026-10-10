import SwiftUI
import AppKit

/// AppKit-backed click catcher that fires single- and double-click callbacks
/// without the disambiguation delay SwiftUI's `.onTapGesture(count:)` pair
/// incurs. AppKit sets `NSEvent.clickCount` synchronously on `mouseDown`, so a
/// lone click fires the single-click callback on the first event; a double
/// click fires single on the first event and double on the second — matching
/// NSTableView selection-then-open behavior.
///
/// A press also reports where it landed, measured down from the view's top
/// edge, and the drag and release that follow report the pointer's height in
/// window coordinates, so the owner can track a drag across rows.
final class ClickCatcherNSView: NSView {
    var onSingleClick: ((_ yFromTop: CGFloat, _ windowY: CGFloat) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDrag: ((_ windowY: CGFloat) -> Void)?
    var onMouseUp: ((_ windowY: CGFloat) -> Void)?

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            let point = convert(event.locationInWindow, from: nil)
            let yFromTop = isFlipped ? point.y : bounds.height - point.y
            onSingleClick?(yFromTop, event.locationInWindow.y)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.y)
    }

    override func mouseUp(with event: NSEvent) {
        onMouseUp?(event.locationInWindow.y)
    }
}

struct ClickCatcherView: NSViewRepresentable {
    let onSingleClick: (_ yFromTop: CGFloat, _ windowY: CGFloat) -> Void
    let onDoubleClick: () -> Void
    var onDrag: (_ windowY: CGFloat) -> Void = { _ in }
    var onMouseUp: (_ windowY: CGFloat) -> Void = { _ in }

    func makeNSView(context: Context) -> ClickCatcherNSView {
        let view = ClickCatcherNSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: ClickCatcherNSView, context: Context) {
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
        nsView.onDrag = onDrag
        nsView.onMouseUp = onMouseUp
    }
}
