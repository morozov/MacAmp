import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppCommands: Commands {
    @Bindable var dockingController: DockingController
    @Bindable var audioPlayer: AudioPlayer
    @Bindable var settings: AppSettings
    var playbackCoordinator: PlaybackCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Options") {
            Button(dockingController.showMain ? "Hide Main" : "Show Main") { dockingController.toggleMain() }
                .keyboardShortcut(WinampKeyBindings.toggleMainWindow.shortcut)
            Button(dockingController.showPlaylist ? "Hide Playlist" : "Show Playlist") { dockingController.togglePlaylist() }
                .keyboardShortcut(WinampKeyBindings.togglePlaylistWindow.shortcut)
            Button(dockingController.showEqualizer ? "Hide Equalizer" : "Show Equalizer") { dockingController.toggleEqualizer() }
                .keyboardShortcut(WinampKeyBindings.toggleEqualizerWindow.shortcut)

            Divider()

            Button("Shade/Unshade Main") { settings.isMainWindowShaded.toggle() }
                .keyboardShortcut(WinampKeyBindings.shadeMainWindow.shortcut)
            Button("Shade/Unshade Playlist") { dockingController.toggleShade(.playlist) }
                .keyboardShortcut(WinampKeyBindings.shadePlaylistWindow.shortcut)
            Button("Shade/Unshade Equalizer") { dockingController.toggleShade(.equalizer) }
                .keyboardShortcut(WinampKeyBindings.shadeEqualizerWindow.shortcut)

            Divider()

            // Clutter bar functions. Cmd+A is context-sensitive — the playlist
            // window's keyDown monitor intercepts it as Select All when the
            // playlist is key.
            Button(settings.isDoubleSizeMode ? "Normal Size" : "Double Size") {
                settings.isDoubleSizeMode.toggle()
            }
            .keyboardShortcut(WinampKeyBindings.doubleSize.shortcut)

            Button("Always On Top") {
                settings.isAlwaysOnTop.toggle()
            }
            .keyboardShortcut(WinampKeyBindings.alwaysOnTop.shortcut)

            Button("Options Menu") {
                settings.showOptionsMenuTrigger = true
            }
            .keyboardShortcut(WinampKeyBindings.openOptionsMenu.shortcut)

            Button("Time: \(settings.timeDisplayMode == .elapsed ? "Show Remaining" : "Show Elapsed")") {
                settings.toggleTimeDisplayMode()
            }
            .keyboardShortcut(WinampKeyBindings.timeMode.shortcut)

            Button("Track Information") {
                settings.showTrackInfoDialog = true
            }
            .keyboardShortcut(WinampKeyBindings.trackInfo.shortcut)

            // Repeat: plain `R` via WinampHotkeyMonitor matches Webamp.
            Button(audioPlayer.repeatMode.label) {
                audioPlayer.repeatMode = audioPlayer.repeatMode.next()
            }

            // Video Window toggle. Plain `V` (Webamp stop) is in the hotkey
            // monitor and `⌘V` is system Paste, so video uses `⌘⇧V`.
            Button(settings.showVideoWindow ? "Hide Video Window" : "Show Video Window") {
                settings.showVideoWindow.toggle()
            }
            .keyboardShortcut(WinampKeyBindings.videoWindow.shortcut)

            // Milkdrop Window toggle - setting change triggers observer
            Button(settings.showMilkdropWindow ? "Hide Milkdrop" : "Show Milkdrop") {
                settings.showMilkdropWindow.toggle()
            }
            .keyboardShortcut(WinampKeyBindings.milkdrop.shortcut)

            // NOTE: Ctrl+1/Ctrl+2 removed - VIDEO window now uses drag resize with 1x/2x button presets

            // Vertical stacking - no horizontal movement needed
            // Windows now stack vertically in fixed order: Main -> EQ -> Playlist
        }
        
        CommandGroup(replacing: .newItem) {
            Button("Open Files...") {
                presentOpenPanel()
            }
            .keyboardShortcut(WinampKeyBindings.openFiles.shortcut)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Preferences...") {
                openWindow(id: "preferences")
            }
            .keyboardShortcut(WinampKeyBindings.preferences.shortcut)
        }
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Audio Files"
        let cueType = UTType(filenameExtension: "cue") ?? .plainText
        panel.allowedContentTypes = [.audio, cueType]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in
                let wasEmpty = audioPlayer.playlist.isEmpty
                for url in panel.urls {
                    let ext = url.pathExtension.lowercased()
                    if ext == "cue" {
                        // Direct `.cue` open is an explicit user request, so a parse
                        // failure surfaces as an alert rather than being swallowed.
                        do {
                            let parsed = try await CueParser.parse(fileURL: url)
                            audioPlayer.addCueTracks(parsed.tracks)
                        } catch {
                            WinampAlertHelper.showError(
                                title: "Failed to Load CUE Sheet",
                                message: error.localizedDescription
                            )
                        }
                    } else if let sidecar = CueParser.sidecarCueURL(for: url) {
                        // Opportunistic sidecar: parse failure or a FILE directive that
                        // resolves to a different audio file falls back silently to a
                        // normal whole-file add.
                        var sidecarConsumed = false
                        do {
                            let parsed = try await CueParser.parse(fileURL: sidecar)
                            if parsed.audioFileURL.standardizedFileURL == url.standardizedFileURL {
                                sidecarConsumed = audioPlayer.addCueTracks(parsed.tracks)
                            } else {
                                AppLog.debug(
                                    .audio,
                                    "Ignoring sidecar CUE \(sidecar.lastPathComponent): FILE resolves to '\(parsed.audioFileURL.lastPathComponent)', expected '\(url.lastPathComponent)'"
                                )
                            }
                        } catch {
                            AppLog.debug(
                                .audio,
                                "Ignoring sidecar CUE \(sidecar.lastPathComponent): \(error.localizedDescription)"
                            )
                        }
                        if !sidecarConsumed {
                            audioPlayer.addTrack(url: url)
                        }
                    } else {
                        audioPlayer.addTrack(url: url)
                    }
                }
                if wasEmpty, let firstTrack = audioPlayer.playlist.first {
                    await playbackCoordinator.play(track: firstTrack)
                }
            }
        }
    }
}
