import SwiftUI
import AppKit

@MainActor
final class PlaylistSpritePopupHost: NSObject {
    static var current: PlaylistSpritePopupHost?

    private let panel: NSPanel
    private weak var parentWindow: NSWindow?
    private let monitors: LocalEventMonitorRegistration
    private let notifications: NotificationCenter
    private var localEventMonitor: Any?
    private var deactivateObserver: NSObjectProtocol?
    private var isDismissed = false

    init(
        panel: NSPanel,
        parentWindow: NSWindow,
        monitors: LocalEventMonitorRegistration = .appKit,
        notifications: NotificationCenter = .default
    ) {
        self.panel = panel
        self.parentWindow = parentWindow
        self.monitors = monitors
        self.notifications = notifications
        super.init()
    }

    private convenience init(
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

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.init(panel: panel, parentWindow: parentWindow)

        panel.isFloatingPanel = true
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.level = .floating
        panel.hidesOnDeactivate = false

        let rootView = PlaylistSpritePopup(tiles: tiles, barSprite: barSprite) { [weak self] action in
            self?.select(action)
        }
        .environment(skinManager)

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
    }

    static func show(
        tiles: [PlaylistSpritePopupTile],
        barSprite: String,
        screenOrigin: NSPoint,
        skinManager: SkinManager,
        parentWindow: NSWindow
    ) {
        let host = PlaylistSpritePopupHost(
            tiles: tiles,
            barSprite: barSprite,
            screenOrigin: screenOrigin,
            skinManager: skinManager,
            parentWindow: parentWindow
        )
        host.activate()
        if !UnitTestSupport.isActive { host.panel.orderFront(nil) }
    }

    func activate() {
        guard !isDismissed, Self.current !== self else { return }
        Self.current?.dismiss()
        Self.current = self
        parentWindow?.addChildWindow(panel, ordered: .above)
        installEventMonitor()
    }

    func select(_ action: () -> Void) {
        withExtendedLifetime(self) {
            guard !isDismissed else { return }
            dismiss()
            action()
        }
    }

    private func installEventMonitor() {
        localEventMonitor = monitors.add(
            [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handle(event, in: event.window)
        }

        // Match NSMenu behavior: dismiss on app deactivate.
        deactivateObserver = notifications.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismiss()
            }
        }
    }

    func handle(_ event: NSEvent, in eventWindow: NSWindow?) -> NSEvent? {
        guard !isDismissed else { return event }
        if event.type == .keyDown {
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard event.keyCode == 53, modifiers.isEmpty,
                  let parentWindow, eventWindow === parentWindow else { return event }
            dismiss()
            return nil
        }
        if eventWindow !== panel { dismiss() }
        return event
    }

    func dismiss() {
        guard !isDismissed else { return }
        isDismissed = true
        if let monitor = localEventMonitor {
            localEventMonitor = nil
            monitors.remove(monitor)
        }
        if let observer = deactivateObserver {
            deactivateObserver = nil
            notifications.removeObserver(observer)
        }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if Self.current === self {
            Self.current = nil
        }
    }
}
