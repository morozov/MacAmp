import AppKit
import AVKit
import WebKit

/// The window that goes to the Dock in place of the player's windows, so the minimize animation shows the whole group.
@MainActor
enum GroupMinimizeProxy {
    /// A borderless, miniaturizable window over the union of `windows` (front to back) that shows a picture of them.
    /// Not ordered in. Video draws black. Nil when `windows` is empty or a window cannot be drawn.
    static func make(for windows: [NSWindow]) async -> NSWindow? {
        guard let front = windows.first else { return nil }
        let union = windows.dropFirst().reduce(front.frame) { $0.union($1.frame) }
        var layers: [(rep: NSBitmapImageRep, frame: CGRect, overlays: [Overlay])] = []
        for window in windows.reversed() {
            guard let content = window.contentView,
                  let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
            content.cacheDisplay(in: content.bounds, to: rep)
            layers.append((rep, window.frame, await overlays(in: content)))
        }
        guard let image = composite(layers, in: union, scale: windows.map(\.backingScaleFactor).max() ?? 1) else { return nil }

        let proxy = NSWindow(contentRect: union, styleMask: [.borderless, .miniaturizable], backing: .buffered, defer: false)
        proxy.isReleasedWhenClosed = false
        proxy.isRestorable = false
        proxy.isOpaque = false
        proxy.backgroundColor = .clear
        proxy.hasShadow = true
        proxy.ignoresMouseEvents = true
        proxy.animationBehavior = .none
        proxy.level = windows.map(\.level).max() ?? front.level
        proxy.collectionBehavior = front.collectionBehavior
        proxy.title = ProcessInfo.processInfo.processName
        let view = NSImageView(frame: NSRect(origin: .zero, size: union.size))
        view.image = image
        view.imageScaling = .scaleNone
        proxy.contentView = view
        return proxy
    }

    /// Content `cacheDisplay` leaves out: the video layer and the out-of-process web view.
    private enum Overlay {
        case black(CGRect)
        case image(NSImage, CGRect)
    }

    /// Rects are in window coordinates.
    private static func overlays(in view: NSView) async -> [Overlay] {
        let rect = view.convert(view.bounds, to: nil)
        if view is AVPlayerView { return [.black(rect)] }
        if let web = view as? WKWebView {
            guard let snapshot = try? await web.takeSnapshot(configuration: nil) else { return [.black(rect)] }
            return [.image(snapshot, rect)]
        }
        var result: [Overlay] = []
        for subview in view.subviews where !subview.isHidden {
            result += await overlays(in: subview)
        }
        return result
    }

    /// `layers` are back to front, each at its screen frame.
    private static func composite(
        _ layers: [(rep: NSBitmapImageRep, frame: CGRect, overlays: [Overlay])], in union: CGRect, scale: CGFloat
    ) -> NSImage? {
        guard let canvas = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((union.width * scale).rounded(.up)),
            pixelsHigh: Int((union.height * scale).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        // Sized before the context exists, so the context draws in points at the backing scale.
        canvas.size = union.size
        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for layer in layers {
            let origin = CGPoint(x: layer.frame.minX - union.minX, y: layer.frame.minY - union.minY)
            layer.rep.draw(in: CGRect(origin: origin, size: layer.frame.size))
            for overlay in layer.overlays {
                switch overlay {
                case .black(let rect):
                    NSColor.black.setFill()
                    rect.offsetBy(dx: origin.x, dy: origin.y).fill()
                case .image(let image, let rect):
                    image.draw(in: rect.offsetBy(dx: origin.x, dy: origin.y))
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: union.size)
        image.addRepresentation(canvas)
        return image
    }
}
