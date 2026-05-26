import AppKit
import SwiftUI

/// NSHostingView subclass that accepts first-mouse events. Without this,
/// clicking SwiftUI content in an inactive MacAmp window only activates the
/// window — the click itself is swallowed, so drags (slider thumb, EQ band,
/// volume knob, etc.) require a second mousedown. Classic Winamp delivers the
/// first click immediately, and so does this hosting view.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}

/// Vanilla `NSViewController` that hosts a `FirstMouseHostingView`. We
/// deliberately do NOT subclass `NSHostingController` here: that class
/// constructs its hosting view via internal mechanisms that bypass
/// `loadView()`, so a subclass cannot intercept the view it serves.
///
/// The hosting view's `sizingOptions = [.preferredContentSize]` mirrors the
/// `NSHostingController.sizingOptions = [.preferredContentSize]` behavior the
/// window controllers previously relied on: SwiftUI content-size changes
/// propagate to this controller's `preferredContentSize`, which causes the
/// hosting NSWindow to resize automatically (e.g., when shade mode toggles).
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
        hosting.sizingOptions = [.preferredContentSize]
        view = hosting
    }
}
