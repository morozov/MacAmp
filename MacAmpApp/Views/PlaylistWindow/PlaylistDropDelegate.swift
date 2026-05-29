import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// AppKit-backed Finder-drop receiver for the playlist content area.
///
/// SwiftUI's `DropDelegate` was unreliable here: dropExited didn't fire on
/// Escape-cancel, and the body-render cycle re-installed the delegate after
/// `performDrop` returned, causing dropEntered to re-fire against the still-
/// hovered cursor with the now-populated playlist count — the retroactive
/// marker symptom. AppKit's `NSDraggingDestination` gives us:
///
/// - Stable identity (`NSView` is a class), so the receiver isn't re-installed
///   on every SwiftUI render.
/// - `draggingEnded(_:)` called on every drag termination — accept, reject,
///   cancel, drag-outside — so the marker always clears.
///
/// The hosted SwiftUI content lives as a subview of the receiver, putting the
/// receiver in the AppKit ancestor chain so the drag walk-up from a deeply
/// hit-tested child (e.g. a track row's NSView) reaches it.
struct PlaylistDropContainer<Content: View>: NSViewRepresentable {
    let content: Content
    let onEntered: (CGPoint) -> Void
    let onUpdated: (CGPoint) -> Void
    let onEnded: () -> Void
    let onPerform: (CGPoint, [URL]) -> Bool

    func makeNSView(context: Context) -> PlaylistDropNSView {
        let view = PlaylistDropNSView()
        view.onEntered = onEntered
        view.onUpdated = onUpdated
        view.onEnded = onEnded
        view.onPerform = onPerform
        view.registerForDraggedTypes([.fileURL])

        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting)
        view.hosting = hosting
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        return view
    }

    func updateNSView(_ nsView: PlaylistDropNSView, context: Context) {
        nsView.onEntered = onEntered
        nsView.onUpdated = onUpdated
        nsView.onEnded = onEnded
        nsView.onPerform = onPerform
        (nsView.hosting as? NSHostingView<Content>)?.rootView = content
    }
}

final class PlaylistDropNSView: NSView {
    var hosting: NSView?
    var onEntered: ((CGPoint) -> Void)?
    var onUpdated: ((CGPoint) -> Void)?
    var onEnded: (() -> Void)?
    var onPerform: ((CGPoint, [URL]) -> Bool)?

    /// Flip so the y axis matches SwiftUI's top-down convention — drop-index
    /// math elsewhere already assumes top-origin.
    override var isFlipped: Bool { true }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        onEntered?(point)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        onUpdated?(point)
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [NSURL])?
            .map { $0 as URL } ?? []
        guard !urls.isEmpty else { return false }
        return onPerform?(point, urls) ?? false
    }

    /// Called for every drag termination (accept, reject, cancel,
    /// drag-outside, app loses focus). The marker clears here unconditionally
    /// — draggingExited isn't enough on its own.
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onEnded?()
    }
}
