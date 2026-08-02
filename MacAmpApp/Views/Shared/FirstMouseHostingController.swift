import AppKit
import SwiftUI

/// NSHostingView subclass that accepts first-mouse events and forwards its
/// SwiftUI-driven intrinsic size onto the containing view controller's
/// `preferredContentSize`. Without `acceptsFirstMouse`, clicking SwiftUI
/// content in an inactive MacAmp window only activates the window — the
/// click itself is swallowed, so drags (titlebar, slider thumb, EQ band,
/// volume knob, etc.) require a second mousedown. Classic Winamp delivers
/// the first click immediately.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    weak var preferredContentSizeOwner: NSViewController?

    /// Whether an intrinsic size is worth measuring at all. A window that sizes
    /// itself explicitly reads neither `intrinsicContentSize` nor
    /// `preferredContentSize`, and the layout pass calls the invalidation hook
    /// once per subview on every display cycle — enough, in a window whose
    /// content animates, to cost more than everything it draws.
    private var tracksIntrinsicSize: Bool { preferredContentSizeOwner != nil }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func invalidateIntrinsicContentSize() {
        guard tracksIntrinsicSize else { return }
        super.invalidateIntrinsicContentSize()
        forwardPreferredContentSize()
    }

    override func layout() {
        super.layout()
        guard tracksIntrinsicSize else { return }
        forwardPreferredContentSize()
    }

    private func forwardPreferredContentSize() {
        guard let owner = preferredContentSizeOwner else { return }
        let size = intrinsicContentSize
        guard size.width > 0, size.height > 0 else { return }
        guard size != owner.preferredContentSize else { return }
        owner.preferredContentSize = size
    }
}

/// Vanilla `NSViewController` hosting a `FirstMouseHostingView`. We can't
/// subclass `NSHostingController` to swap its hosting view (it constructs
/// the view through internal mechanisms that bypass `loadView`), so this
/// controller is the smallest wrapper that combines first-mouse delivery
/// with the window-auto-resize that `NSHostingController.sizingOptions =
/// [.preferredContentSize]` would give for free.
///
/// `NSHostingView.sizingOptions = [.preferredContentSize]` updates the
/// view's `intrinsicContentSize` when SwiftUI's measured size changes, but
/// a vanilla `NSViewController` doesn't bridge that to its own
/// `preferredContentSize` — and `preferredContentSize` is what AppKit reads
/// to resize the window. Forward the change explicitly from both
/// `invalidateIntrinsicContentSize` and `layout` (SwiftUI doesn't always go
/// through `invalidate` when the intrinsic size shifts under shade toggle).
@MainActor
final class FirstMouseHostingController<Content: View>: NSViewController {
    private let rootView: Content
    private let autoSizesWindow: Bool

    /// - Parameter autoSizesWindow: When `true`, the hosting view tracks
    ///   SwiftUI's intrinsic size and forwards it to `preferredContentSize` so
    ///   the window follows content-size changes automatically. This re-measures
    ///   the whole SwiftUI tree on every content update, so a window that
    ///   updates at a high rate (the main window's visualizer/time/position)
    ///   MUST pass `false` and resize its window explicitly instead.
    init(rootView: Content, autoSizesWindow: Bool = true) {
        self.rootView = rootView
        self.autoSizesWindow = autoSizesWindow
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let hosting = FirstMouseHostingView(rootView: rootView)
        if autoSizesWindow {
            // `.intrinsicContentSize` makes the hosting view expose SwiftUI's
            // measured size through `intrinsicContentSize`. The sibling
            // `.preferredContentSize` option *should* also update the closest
            // view controller's `preferredContentSize` automatically, but in
            // practice it no-ops when the controller is a vanilla
            // NSViewController (only NSHostingController bridges natively).
            // Forward it manually via the hosting view's layout hooks instead.
            hosting.sizingOptions = [.intrinsicContentSize]
            hosting.preferredContentSizeOwner = self
        } else {
            hosting.sizingOptions = []
        }
        view = hosting
    }
}