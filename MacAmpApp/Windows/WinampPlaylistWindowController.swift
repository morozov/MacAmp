import AppKit
import SwiftUI

@MainActor
class WinampPlaylistWindowController: NSWindowController {
    convenience init(skinManager: SkinManager, audioPlayer: AudioPlayer, dockingController: DockingController, settings: AppSettings, radioLibrary: RadioStationLibrary, playbackCoordinator: PlaybackCoordinator, windowFocusState: WindowFocusState) {
        // Playlist is segment-resized through PlaylistResizeHandle, which drives
        // sizeState and lets `[.preferredContentSize]` propagate the new size to
        // the NSWindow. The `.resizable` styleMask would also expose macOS's
        // invisible edge-resize zones — those fire ahead of the SwiftUI gesture,
        // grow the window without updating sizeState, and leave the SwiftUI
        // content centered inside the larger frame with transparent gaps.
        let window = BorderlessWindow(
            contentRect: NSRect(x: 0, y: 0, width: 275, height: 232),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Programmatic setFrame still honors min/max.
        window.minSize = NSSize(
            width: PlaylistWindowSizeState.baseWidth,
            height: PlaylistWindowSizeState.baseHeight
        )
        window.maxSize = NSSize(width: 2000, height: 900)

        // CRITICAL FIX #2: Apply standard Winamp window configuration
        WinampWindowConfigurator.apply(to: window)

        window.hasShadow = true

        // Create view with environment injection
        let rootView = WinampPlaylistWindow()
            .environment(skinManager)
            .environment(audioPlayer)
            .environment(dockingController)
            .environment(settings)
            .environment(radioLibrary)
            .environment(playbackCoordinator)
            .environment(windowFocusState)

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
