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

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        forwardPreferredContentSize()
    }

    override func layout() {
        super.layout()
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

    init(rootView: Content) {
        self.rootView = rootView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let hosting = FirstMouseHostingView(rootView: rootView)
        // `.intrinsicContentSize` makes the hosting view expose SwiftUI's
        // measured size through `intrinsicContentSize`. The sibling
        // `.preferredContentSize` option *should* also update the closest
        // view controller's `preferredContentSize` automatically, but in
        // practice it no-ops when the controller is a vanilla
        // NSViewController (only NSHostingController bridges natively).
        // Forward it manually via the hosting view's layout hooks instead.
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.preferredContentSizeOwner = self
        view = hosting
    }
}
