import SwiftUI
import AppKit

@MainActor
final class PlaylistSpritePopupHost: NSObject {
    static var current: PlaylistSpritePopupHost?

    private let panel: NSPanel
    private var localEventMonitor: Any?
    private var deactivateObserver: NSObjectProtocol?

    private init(
        tiles: [PlaylistSpritePopupTile],
        barSprite: String,
        screenOrigin: NSPoint,
        skinManager: SkinManager,
        parentWindow: NSWindow
    ) {
        let size = NSSize(
            width: PlaylistSpritePopup.barWidth + PlaylistSpritePopup.tileWidth,
            height: PlaylistSpritePopup.tileHeight * CGFloat(tiles.count)
        )
        let frame = NSRect(origin: screenOrigin, size: size)

        self.panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isFloatingPanel = true
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.level = .floating
        panel.hidesOnDeactivate = false

        let rootView = PlaylistSpritePopup(tiles: tiles, barSprite: barSprite) { [weak self] in
            self?.dismiss()
        }
        .environment(skinManager)

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting

        parentWindow.addChildWindow(panel, ordered: .above)
    }

    static func show(
        tiles: [PlaylistSpritePopupTile],
        barSprite: String,
        screenOrigin: NSPoint,
        skinManager: SkinManager,
        parentWindow: NSWindow
    ) {
        current?.dismiss()
        let host = PlaylistSpritePopupHost(
            tiles: tiles,
            barSprite: barSprite,
            screenOrigin: screenOrigin,
            skinManager: skinManager,
            parentWindow: parentWindow
        )
        current = host
        host.installEventMonitor()
        host.panel.orderFront(nil)
    }

    private func installEventMonitor() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }

            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.dismiss()
                    return nil
                }
                return event
            }

            if event.window !== self.panel {
                self.dismiss()
            }
            return event
        }

        // Match NSMenu behavior: dismiss on app deactivate.
        deactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let observer = deactivateObserver {
            NotificationCenter.default.removeObserver(observer)
            deactivateObserver = nil
        }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if Self.current === self {
            Self.current = nil
        }
    }
}
