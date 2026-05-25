import SwiftUI
import AppKit

/// AppKit-backed click catcher that fires single- and double-click callbacks
/// without the disambiguation delay SwiftUI's `.onTapGesture(count:)` pair
/// incurs. AppKit sets `NSEvent.clickCount` synchronously on `mouseDown`, so a
/// lone click fires the single-click callback on the first event; a double
/// click fires single on the first event and double on the second — matching
/// NSTableView selection-then-open behavior.
final class ClickCatcherNSView: NSView {
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            onSingleClick?()
        }
    }
}

struct ClickCatcherView: NSViewRepresentable {
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> ClickCatcherNSView {
        let view = ClickCatcherNSView()
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: ClickCatcherNSView, context: Context) {
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
    }
}
