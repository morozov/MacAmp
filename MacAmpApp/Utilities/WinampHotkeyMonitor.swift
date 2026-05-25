import AppKit

/// App-level keyDown monitor implementing Winamp's plain-key hotkeys.
/// Mirrors `packages/webamp/js/hotkeys.ts` for the non-modifier shortcuts:
/// Z/X/C/V/B for prev/play/pause/stop/next, L open file, R repeat, S shuffle,
/// ←/→ seek ±5s, ↑/↓ volume ±1%. Plus Webamp's Alt+W/E/G window toggles
/// remapped to Option+W/E/G for Mac-native modifier semantics.
///
/// Modifier-key menu shortcuts (⌘D double-size, ⌘T time mode, ⌘A always-on-top
/// / select-all) stay in `AppCommands.swift` so they appear in the menu UI.
@MainActor
final class WinampHotkeyMonitor {
    private let audioPlayer: AudioPlayer
    private let playbackCoordinator: PlaybackCoordinator
    private let dockingController: DockingController
    private let presentOpenPanel: () -> Void
    private var monitor: Any?

    init(
        audioPlayer: AudioPlayer,
        playbackCoordinator: PlaybackCoordinator,
        dockingController: DockingController,
        presentOpenPanel: @escaping () -> Void
    ) {
        self.audioPlayer = audioPlayer
        self.playbackCoordinator = playbackCoordinator
        self.dockingController = dockingController
        self.presentOpenPanel = presentOpenPanel
        install()
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Cannot use `self?.handle(event) ?? event`: Swift collapses the
            // optional chain into a single `NSEvent?`, so `?? event` replaces
            // a legitimate "consume" (nil) return from `handle` with the
            // original event, defeating the suppression and producing an
            // AppKit `NSBeep()` for keys we already acted on.
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if isEditingText(in: event.window) { return event }

        let appShortcutModifiers = event.modifierFlags.intersection([.command, .option, .control])

        if appShortcutModifiers == .option {
            return handleOptionKey(event)
        }
        guard appShortcutModifiers.isEmpty else { return event }

        switch event.keyCode {
        case 123: seekBy(-5); return nil   // ←
        case 124: seekBy(+5); return nil   // →
        case 125: adjustVolume(by: -1); return nil  // ↓
        case 126: adjustVolume(by: +1); return nil  // ↑
        default:
            break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z":
            Task { await playbackCoordinator.previous() }
        case "x":
            startPlayback()
        case "c":
            playbackCoordinator.togglePlayPause()
        case "v":
            playbackCoordinator.stop()
        case "b":
            Task { await playbackCoordinator.next() }
        case "l":
            presentOpenPanel()
        case "r":
            audioPlayer.repeatMode = audioPlayer.repeatMode.next()
        case "s":
            audioPlayer.shuffleEnabled.toggle()
        default:
            return event
        }
        return nil
    }

    private func handleOptionKey(_ event: NSEvent) -> NSEvent? {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "w":
            dockingController.toggleMain()
        case "e":
            dockingController.togglePlaylist()
        case "g":
            dockingController.toggleEqualizer()
        default:
            return event
        }
        return nil
    }

    /// Webamp's `play()` thunk: keep playing if already playing, resume if
    /// paused, otherwise start the current/first track. Open-file fallback for
    /// the truly-empty case stays with plain `L`.
    private func startPlayback() {
        if playbackCoordinator.isPaused {
            playbackCoordinator.togglePlayPause()
        } else if !playbackCoordinator.isPlaying {
            audioPlayer.play()
        }
    }

    private func seekBy(_ seconds: Double) {
        guard case .localTrack = playbackCoordinator.currentSource else { return }
        let newTime = max(0, audioPlayer.currentTime + seconds)
        audioPlayer.seek(to: newTime)
    }

    private func adjustVolume(by deltaPercent: Int) {
        let currentPct = Int((audioPlayer.volume * 100).rounded())
        let newPct = max(0, min(100, currentPct + deltaPercent))
        guard newPct != currentPct else { return }
        playbackCoordinator.setVolume(Float(newPct) / 100)
        playbackCoordinator.commitVolume()
    }

    private func isEditingText(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder is NSText { return true }
        if responder is NSTextField { return true }
        return false
    }
}
