import AppKit
import SwiftUI

@MainActor
class WinampMainWindowController: NSWindowController {
    private let settings: AppSettings

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

        // Stable handle for UI tests to locate the main window in the
        // accessibility tree; inert for normal use.
        window.setAccessibilityIdentifier("MacAmp.MainWindow")

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
        // Auto-sizing is off (see below): tracking SwiftUI's intrinsic size
        // re-lays out the whole window on every visualizer/time/position update.
        // Shade toggle is resized explicitly instead.
        let hostingController = FirstMouseHostingController(rootView: rootView, autoSizesWindow: false)
        let hostingView = hostingController.view
        hostingView.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        hostingView.autoresizingMask = [.width, .height]

        window.contentViewController = hostingController
        window.contentView = hostingView
        window.makeFirstResponder(hostingView)

        // Install translucent backing layer (prevents bleed-through)
        WinampWindowConfigurator.installHitSurface(on: window)

        self.init(window: window, settings: settings)
    }

    init(window: NSWindow, settings: AppSettings) {
        self.settings = settings
        super.init(window: window)
        applyShadeSize()
        observeShade()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Re-arming observation of the shade flag. The hosting view no longer
    /// resizes the window automatically, so collapse/expand the window here.
    private func observeShade() {
        withObservationTracking {
            _ = settings.isMainWindowShaded
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyShadeSize()
                self.observeShade()
            }
        }
    }

    /// Size the window to the current shade/double-size combination, keeping the
    /// top-left fixed so the title bar stays put when the body collapses.
    private func applyShadeSize() {
        guard let window else { return }
        let base = settings.isMainWindowShaded ? WinampSizes.mainShade : WinampSizes.main
        let scale: CGFloat = settings.isDoubleSizeMode ? 2 : 1
        let newSize = CGSize(width: base.width * scale, height: base.height * scale)
        let old = window.frame
        let newFrame = NSRect(x: old.minX, y: old.maxY - newSize.height, width: newSize.width, height: newSize.height)
        guard newFrame != old else { return }
        window.setFrame(newFrame, display: true)
    }
}
