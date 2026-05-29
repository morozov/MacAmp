import AppKit
import SwiftUI

@MainActor
class WinampMainWindowController: NSWindowController {
    convenience init(skinManager: SkinManager, audioPlayer: AudioPlayer, dockingController: DockingController, settings: AppSettings, radioLibrary: RadioStationLibrary, playbackCoordinator: PlaybackCoordinator, windowFocusState: WindowFocusState, userActionDispatcher: UserActionDispatcher) {
        // ORACLE BLOCKING ISSUE #1 FIX: Truly borderless windows
        // .borderless = 0, so [.borderless, .titled] keeps .titled mask!
        // For custom Winamp chrome, use .borderless ONLY (no system chrome)

        // CRITICAL: Use BorderlessWindow subclass for canBecomeKey/canBecomeMain
        // Standard borderless NSWindow doesn't accept first responder
        let window = BorderlessWindow(
            contentRect: NSRect(x: 0, y: 0, width: 275, height: 116),
            styleMask: [.borderless],  // ONLY borderless - no .titled!
            backing: .buffered,
            defer: false
        )

        // CRITICAL FIX #2: Apply standard Winamp window configuration
        // Extracted from UnifiedDockView.configureWindow()
        WinampWindowConfigurator.apply(to: window)

        window.hasShadow = true

        // Create view with environment injection
        let rootView = WinampMainWindow()
            .environment(skinManager)
            .environment(audioPlayer)
            .environment(dockingController)
            .environment(settings)
            .environment(radioLibrary)
            .environment(playbackCoordinator)
            .environment(windowFocusState)
            .environment(userActionDispatcher)

        // FirstMouseHostingController combines first-click delivery (so
        // dragging the titlebar / slider on an inactive window works on the
        // first mousedown) with SwiftUI-driven window resize (shade toggle
        // and double-size flip propagate through the hosting view's
        // intrinsic size to this controller's preferredContentSize).
        let hostingController = FirstMouseHostingController(rootView: rootView)
        let hostingView = hostingController.view
        hostingView.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        hostingView.autoresizingMask = [.width, .height]

        window.contentViewController = hostingController
        window.contentView = hostingView
        window.makeFirstResponder(hostingView)

        // Install translucent backing layer (prevents bleed-through)
        WinampWindowConfigurator.installHitSurface(on: window)

        self.init(window: window)
    }
}
