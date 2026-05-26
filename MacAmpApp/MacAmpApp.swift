import SwiftUI
import AppKit

@main
struct MacAmpApp: App {
    @State private var skinManager: SkinManager
    @State private var audioPlayer: AudioPlayer
    @State private var dockingController: DockingController
    @State private var settings: AppSettings
    @State private var radioLibrary: RadioStationLibrary
    @State private var streamPlayer: StreamPlayer
    @State private var playbackCoordinator: PlaybackCoordinator
    @State private var windowFocusState: WindowFocusState
    @State private var playlistStateStore: PlaylistStateStore

    init() {
        let skinManager = SkinManager()
        let audioPlayer = AudioPlayer()
        let dockingController = DockingController()
        let settings = AppSettings.instance()
        let radioLibrary = RadioStationLibrary()
        let streamPlayer = StreamPlayer()
        let playbackCoordinator = PlaybackCoordinator(audioPlayer: audioPlayer, streamPlayer: streamPlayer)

        // Spec 005: restore the persisted playlist + current-track marker
        // before the playlist window has a chance to render. The store itself
        // is constructed AFTER population so its observation loop doesn't
        // fire a redundant save during restore.
        if let snapshot = PlaylistStateStore.restoreSnapshot() {
            audioPlayer.addEntries(snapshot.entries)
            if let idx = snapshot.currentIndex,
               audioPlayer.playlist.indices.contains(idx) {
                playbackCoordinator.selectTrack(audioPlayer.playlist[idx])
            }
        }

        let playlistStateStore = PlaylistStateStore(
            audioPlayer: audioPlayer,
            playbackCoordinator: playbackCoordinator
        )

        // Spec 005: flush any pending debounced save before the process exits.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                playlistStateStore.flushSynchronously()
            }
        }

        _skinManager = State(initialValue: skinManager)
        _audioPlayer = State(initialValue: audioPlayer)
        _dockingController = State(initialValue: dockingController)
        _settings = State(initialValue: settings)
        _radioLibrary = State(initialValue: radioLibrary)
        _streamPlayer = State(initialValue: streamPlayer)
        _playbackCoordinator = State(initialValue: playbackCoordinator)
        _playlistStateStore = State(initialValue: playlistStateStore)

        // CRITICAL FIX #1: Skin auto-loading (from UnifiedDockView.ensureSkin)
        // Load initial skin before creating windows
        if skinManager.currentSkin == nil {
            skinManager.loadInitialSkin()
        }

        // Create window focus state for all windows
        let windowFocusState = WindowFocusState()
        _windowFocusState = State(initialValue: windowFocusState)

        // Initialize WindowCoordinator (creates separate NSWindows for Main, EQ, Playlist, etc.)
        let coordinator = WindowCoordinator(
            skinManager: skinManager,
            audioPlayer: audioPlayer,
            dockingController: dockingController,
            settings: settings,
            radioLibrary: radioLibrary,
            playbackCoordinator: playbackCoordinator,
            windowFocusState: windowFocusState
        )
        WindowCoordinator.shared = coordinator
        WindowCoordinatorBox.shared.value = coordinator
        dockingController.windowCoordinator = coordinator
    }

    var body: some Scene {
        // Main windows are NSWindows created by WindowCoordinator

        // ARCHITECTURAL FIX: Provide a "main" SwiftUI Window scene
        // This satisfies SwiftUI's requirement for at least one main scene
        // The actual UI is in NSWindows created by WindowCoordinator
        WindowGroup(id: "main-placeholder") {
            EmptyView()
                .frame(width: 0, height: 0)
                .hidden()
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .defaultSize(width: 0, height: 0)
        .windowResizability(.contentSize)

        Settings {
            EmptyView()
        }

        WindowGroup("Preferences", id: "preferences") {
            PreferencesView()
                .environment(settings)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // Commands are defined once here and apply to all window groups
        .commands {
            // SwiftUI's auto Edit menu binds ⌘A to Select All. On the playlist
            // window, the underlying NSHostingView responds to selectAll: (a
            // default NSResponder method), enabling the Edit > Select All item
            // and hijacking ⌘A before it reaches our Always On Top. Removing
            // the pasteboard group strips Cut/Copy/Paste/Delete/Select All
            // from the menu; NSText still handles those at the responder
            // level for text fields in Preferences.
            CommandGroup(replacing: .pasteboard) { }
            AppCommands(dockingController: dockingController, audioPlayer: audioPlayer, settings: settings, playbackCoordinator: playbackCoordinator)
            SkinsCommands(skinManager: skinManager)
        }
    }
}
