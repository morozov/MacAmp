import AppKit
import Observation

/// Observable holder for the WindowCoordinator singleton.
///
/// `WindowCoordinator.shared` is a plain static var, so SwiftUI's
/// observation runtime can't track when it's assigned. Window controllers
/// finish constructing — and their `NSHostingController` view bodies first
/// evaluate — while `WindowCoordinator.init` is still in flight, so any
/// view that resolves `WindowCoordinator.shared` at body-eval time
/// captures `nil`. Reading through `WindowCoordinatorBox.shared.value`
/// gives the view a dependency the runtime *does* track, so the nil → set
/// transition triggers a re-render and the next body eval captures the
/// live coordinator into action closures and sprite computations.
@MainActor
@Observable
final class WindowCoordinatorBox {
    @MainActor static let shared = WindowCoordinatorBox()
    var value: WindowCoordinator?
    private init() {}
}

@MainActor
@Observable
final class WindowCoordinator {
    static var shared: WindowCoordinator?  // Initialized in MacAmpApp.init()

    let registry: WindowRegistry
    private let settings: AppSettings
    let skinManager: SkinManager
    private let windowFocusState: WindowFocusState
    let framePersistence: WindowFramePersistence
    let visibility: WindowVisibilityController
    let resizeController: WindowResizeController
    private let settingsObserver: WindowSettingsObserver
    var hasPresentedInitialWindows = false
    private var delegateWiring: WindowDelegateWiring?
    private var zOrderController: WindowZOrderController?
    private var appActivationObserver: NSObjectProtocol?
    private var volumeScrollController: VolumeScrollWheelController?
    private var hotkeyMonitor: WinampHotkeyMonitor?

    var mainWindow: NSWindow? { registry.mainWindow }
    var eqWindow: NSWindow? { registry.eqWindow }
    var playlistWindow: NSWindow? { registry.playlistWindow }
    var videoWindow: NSWindow? { registry.videoWindow }
    var milkdropWindow: NSWindow? { registry.milkdropWindow }
    // swiftlint:disable:next function_body_length
    init(skinManager: SkinManager, audioPlayer: AudioPlayer, dockingController: DockingController, settings: AppSettings, radioLibrary: RadioStationLibrary, playbackCoordinator: PlaybackCoordinator, windowFocusState: WindowFocusState) {
        // Store shared state references
        self.settings = settings
        self.skinManager = skinManager
        self.windowFocusState = windowFocusState

        // Create all window controllers and wrap in registry
        registry = WindowRegistry(
            mainController: WinampMainWindowController(
                skinManager: skinManager, audioPlayer: audioPlayer,
                dockingController: dockingController, settings: settings,
                radioLibrary: radioLibrary, playbackCoordinator: playbackCoordinator,
                windowFocusState: windowFocusState
            ),
            eqController: WinampEqualizerWindowController(
                skinManager: skinManager, audioPlayer: audioPlayer,
                dockingController: dockingController, settings: settings,
                radioLibrary: radioLibrary, playbackCoordinator: playbackCoordinator,
                windowFocusState: windowFocusState
            ),
            playlistController: WinampPlaylistWindowController(
                skinManager: skinManager, audioPlayer: audioPlayer,
                dockingController: dockingController, settings: settings,
                radioLibrary: radioLibrary, playbackCoordinator: playbackCoordinator,
                windowFocusState: windowFocusState
            ),
            videoController: WinampVideoWindowController(
                skinManager: skinManager, audioPlayer: audioPlayer,
                dockingController: dockingController, settings: settings,
                radioLibrary: radioLibrary, playbackCoordinator: playbackCoordinator,
                windowFocusState: windowFocusState
            ),
            milkdropController: WinampMilkdropWindowController(
                skinManager: skinManager, audioPlayer: audioPlayer,
                dockingController: dockingController, settings: settings,
                radioLibrary: radioLibrary, playbackCoordinator: playbackCoordinator,
                windowFocusState: windowFocusState
            )
        )

        // Create persistence controller
        framePersistence = WindowFramePersistence(registry: registry, settings: settings)

        // Create visibility controller
        visibility = WindowVisibilityController(registry: registry, settings: settings)

        // Create resize controller
        resizeController = WindowResizeController(registry: registry, persistence: framePersistence)

        // Create settings observer
        settingsObserver = WindowSettingsObserver(settings: settings)

        // Configure windows (borderless, transparent titlebar)
        configureWindows()

        // Set initial window sizes based on current double-size state
        resizeMainAndEQWindows(
            doubled: settings.isDoubleSizeMode,
            animated: false,
            persistResult: false
        )
        debugLogWindowPositions(step: "after initial resizeMainAndEQWindows")

        // Apply persisted positions or fall back to defaults
        applyInitialWindowLayout()
        debugLogWindowPositions(step: "after applying initial window layout")

        // Show windows only after the initial skin has loaded
        presentWindowsWhenReady()
        debugLogWindowPositions(step: "after presentWindowsWhenReady call")

        // Set initial window levels from persisted always-on-top state
        let initialLevel: NSWindow.Level = settings.isAlwaysOnTop ? .floating : .normal
        mainWindow?.level = initialLevel
        eqWindow?.level = initialLevel
        playlistWindow?.level = initialLevel
        videoWindow?.level = initialLevel
        milkdropWindow?.level = initialLevel
        debugLogWindowPositions(step: "after initial window level assignment")

        // Start observing settings changes (always-on-top, double-size, video, milkdrop)
        settingsObserver.start(
            onAlwaysOnTopChanged: { [weak self] isOn in
                self?.updateWindowLevels(isOn)
            },
            onDoubleSizeChanged: { [weak self] doubled in
                self?.resizeMainAndEQWindows(doubled: doubled)
            },
            onShowVideoChanged: { [weak self] show in
                guard let self else { return }
                if show {
                    if self.hasPresentedInitialWindows { self.showVideo() }
                } else {
                    self.hideVideo()
                }
            },
            onShowMilkdropChanged: { [weak self] show in
                guard let self else { return }
                AppLog.debug(.window, "showMilkdropWindow changed to \(show)")
                if show {
                    if self.hasPresentedInitialWindows { self.showMilkdrop() }
                } else {
                    self.hideMilkdrop()
                }
            }
        )
        debugLogWindowPositions(step: "after settings observer start")

        // Z-order controller keeps MacAmp windows grouped as a single app
        // when another app's window has been raised between them.
        let zOrderController = WindowZOrderController(registry: registry)
        self.zOrderController = zOrderController

        // Wire up snap manager, delegate multiplexers, persistence, and focus delegates
        delegateWiring = WindowDelegateWiring.wire(
            registry: registry,
            persistenceDelegate: framePersistence.persistenceDelegate,
            windowFocusState: windowFocusState
        )
        debugLogWindowPositions(step: "after delegate wiring")

        // Cmd+Tab back into MacAmp (or clicking one sub-window from another
        // app) doesn't fire windowDidBecomeKey on the non-key sub-windows,
        // so observe app activation explicitly. The cascade is intentionally
        // NOT also wired into `windowDidBecomeKey` — routine in-app focus
        // changes can't let a foreign window slip between MacAmp's, and the
        // `orderFront` burst there was cancelling pending SwiftUI `.help()`
        // tooltips (NSToolTipManager treats the notifications as activity
        // and aborts its delay timer).
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak zOrderController] _ in
            MainActor.assumeIsolated {
                zOrderController?.bringAllWindowsForward()
            }
        }

        // Capture scroll-wheel events over main + EQ windows for volume control
        volumeScrollController = VolumeScrollWheelController(
            registry: registry,
            audioPlayer: audioPlayer,
            playbackCoordinator: playbackCoordinator
        )

        // Install Winamp's plain-key hotkeys (Z/X/C/V/B/L/R/S, arrows, Option+W/E/G).
        hotkeyMonitor = WinampHotkeyMonitor(
            audioPlayer: audioPlayer,
            playbackCoordinator: playbackCoordinator,
            dockingController: dockingController,
            presentOpenPanel: { [audioPlayer, playbackCoordinator] in
                PlaylistWindowActions.shared.presentAddFilesPanel(
                    audioPlayer: audioPlayer,
                    playbackCoordinator: playbackCoordinator
                )
            }
        )
    }

    isolated deinit {
        settingsObserver.stop()
        if let appActivationObserver {
            NotificationCenter.default.removeObserver(appActivationObserver)
        }
    }

    // MARK: - Window Resize (forwarded to WindowResizeController)

    private func resizeMainAndEQWindows(doubled: Bool, animated: Bool = true, persistResult: Bool = true) {
        resizeController.resizeMainAndEQWindows(doubled: doubled, animated: animated, persistResult: persistResult)
    }

    func updateVideoWindowSize(to pixelSize: CGSize) { resizeController.updateVideoWindowSize(to: pixelSize) }
    func updateMilkdropWindowSize(to pixelSize: CGSize) { resizeController.updateMilkdropWindowSize(to: pixelSize) }
    func updatePlaylistWindowSize(to pixelSize: CGSize) { resizeController.updatePlaylistWindowSize(to: pixelSize) }

    func showVideoResizePreview(_ overlay: WindowResizePreviewOverlay, previewSize: CGSize) {
        resizeController.showVideoResizePreview(overlay, previewSize: previewSize)
    }

    func hideVideoResizePreview(_ overlay: WindowResizePreviewOverlay) {
        resizeController.hideVideoResizePreview(overlay)
    }

    func showPlaylistResizePreview(_ overlay: WindowResizePreviewOverlay, previewSize: CGSize) {
        resizeController.showPlaylistResizePreview(overlay, previewSize: previewSize)
    }

    func hidePlaylistResizePreview(_ overlay: WindowResizePreviewOverlay) {
        resizeController.hidePlaylistResizePreview(overlay)
    }

    // MARK: - Window Visibility (forwarded to WindowVisibilityController)

    func hideApp() { visibility.hideApp() }
    func showEQWindow() { visibility.showEQWindow() }
    func hideEQWindow() { visibility.hideEQWindow() }
    func toggleEQWindowVisibility() -> Bool { visibility.toggleEQWindowVisibility() }
    func showPlaylistWindow() { visibility.showPlaylistWindow() }
    func hidePlaylistWindow() { visibility.hidePlaylistWindow() }
    func togglePlaylistWindowVisibility() -> Bool { visibility.togglePlaylistWindowVisibility() }

    var isEQWindowVisible: Bool {
        get { visibility.isEQWindowVisible }
        set { visibility.isEQWindowVisible = newValue }
    }

    var isPlaylistWindowVisible: Bool {
        get { visibility.isPlaylistWindowVisible }
        set { visibility.isPlaylistWindowVisible = newValue }
    }

    var isEQWindowCurrentlyVisible: Bool { visibility.isEQWindowCurrentlyVisible }
    var isPlaylistWindowCurrentlyVisible: Bool { visibility.isPlaylistWindowCurrentlyVisible }

    // MARK: - Window Level Management

    private func updateWindowLevels(_ alwaysOnTop: Bool) {
        let level: NSWindow.Level = alwaysOnTop ? .floating : .normal
        mainWindow?.level = level
        eqWindow?.level = level
        playlistWindow?.level = level
        videoWindow?.level = level
        milkdropWindow?.level = level
    }

    func showAllWindows() { visibility.showAllWindows() }
    func showMain() { visibility.showMain() }
    func hideMain() { visibility.hideMain() }
    func showEqualizer() { visibility.showEQWindow(makeKey: true) }
    func hideEqualizer() { visibility.hideEQWindow() }
    func showPlaylist() { visibility.showPlaylistWindow(makeKey: true) }
    func hidePlaylist() { visibility.hidePlaylistWindow() }
    func showVideo() { visibility.showVideo() }
    func hideVideo() { visibility.hideVideo() }
    func showMilkdrop() { visibility.showMilkdrop() }
    func hideMilkdrop() { visibility.hideMilkdrop() }
}
