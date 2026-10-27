import AppKit
import QuartzCore
import SwiftUI

/// The scrolling marquee: the flattened title bitmap in a layer that
/// `WinampMainWindowInteractionState.scrollOffset` moves directly, so a scroll
/// tick commits one layer position and never runs SwiftUI.
struct MarqueeTextView: NSViewRepresentable {
    @Environment(SkinManager.self) private var skinManager
    let text: String
    let interactionState: WinampMainWindowInteractionState

    func makeNSView(context: Context) -> MarqueeTextNSView {
        let view = MarqueeTextNSView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: MarqueeTextNSView, context: Context) {
        update(nsView)
    }

    static func dismantleNSView(_ nsView: MarqueeTextNSView, coordinator: ()) {
        nsView.detach()
    }

    private func update(_ view: MarqueeTextNSView) {
        view.setImage(
            TrackInfoSprites.flatten(text, from: skinManager.currentSkin)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil),
            width: CGFloat(TrackInfoSprites.glyphNames(for: text).count) * 5
        )
        view.attach(to: interactionState)
    }
}

@MainActor
final class MarqueeTextNSView: NSView {
    private let textLayer = CALayer()
    private weak var interactionState: WinampMainWindowInteractionState?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        textLayer.anchorPoint = .zero
        textLayer.magnificationFilter = .nearest
        textLayer.minificationFilter = .nearest
        textLayer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        layer?.addSublayer(textLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        applyOffset(interactionState?.scrollOffset ?? 0)
    }

    fileprivate func setImage(_ image: CGImage?, width: CGFloat) {
        textLayer.contents = image
        textLayer.bounds = CGRect(x: 0, y: 0, width: width, height: 6)
    }

    fileprivate func attach(to state: WinampMainWindowInteractionState) {
        interactionState = state
        state.observeScrollOffset(self) { [weak self] in self?.applyOffset($0) }
        applyOffset(state.scrollOffset)
    }

    fileprivate func detach() {
        interactionState?.stopObservingScrollOffset(self)
        interactionState = nil
    }

    /// Places the text leading-aligned, vertically centered and raised 2 px,
    /// where the static title sits.
    private func applyOffset(_ offset: CGFloat) {
        let y = (bounds.height - textLayer.bounds.height) / 2 - 2
        textLayer.position = CGPoint(x: offset, y: y)
    }
}
