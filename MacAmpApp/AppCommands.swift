import SwiftUI
import AppKit

struct AppCommands: Commands {
    var windowCoordinator: WindowCoordinator
    @Bindable var audioPlayer: AudioPlayer
    @Bindable var settings: AppSettings
    var dispatcher: UserActionDispatcher

    var body: some Commands {
        CommandMenu("Options") {
            Button(windowCoordinator.isMainWindowVisible ? "Hide Main" : "Show Main") {
                dispatcher.perform(WinampKeyBindings.toggleMainWindow.action)
            }
            .keyboardShortcut(WinampKeyBindings.toggleMainWindow.shortcut)

            Button(windowCoordinator.isPlaylistWindowVisible ? "Hide Playlist" : "Show Playlist") {
                dispatcher.perform(WinampKeyBindings.togglePlaylistWindow.action)
            }
            .keyboardShortcut(WinampKeyBindings.togglePlaylistWindow.shortcut)

            Button(windowCoordinator.isEQWindowVisible ? "Hide Equalizer" : "Show Equalizer") {
                dispatcher.perform(WinampKeyBindings.toggleEqualizerWindow.action)
            }
            .keyboardShortcut(WinampKeyBindings.toggleEqualizerWindow.shortcut)

            Divider()

            Button("Shade/Unshade Main") {
                dispatcher.perform(WinampKeyBindings.shadeMainWindow.action)
            }
            .keyboardShortcut(WinampKeyBindings.shadeMainWindow.shortcut)

            Button("Shade/Unshade Playlist") {
                dispatcher.perform(WinampKeyBindings.shadePlaylistWindow.action)
            }
            .keyboardShortcut(WinampKeyBindings.shadePlaylistWindow.shortcut)

            Button("Shade/Unshade Equalizer") {
                dispatcher.perform(WinampKeyBindings.shadeEqualizerWindow.action)
            }
            .keyboardShortcut(WinampKeyBindings.shadeEqualizerWindow.shortcut)

            Button("Windowshade Mode") {
                dispatcher.perform(WinampKeyBindings.windowshadeMode.action)
            }
            .keyboardShortcut(WinampKeyBindings.windowshadeMode.shortcut)

            Button("Minimize All") {
                dispatcher.perform(WinampKeyBindings.minimizeAll.action)
            }
            .keyboardShortcut(WinampKeyBindings.minimizeAll.shortcut)
            .disabled(!windowCoordinator.isMainWindowVisible)

            Button("Reset Window Positions") {
                dispatcher.perform(.resetWindowPositions)
            }

            Divider()

            // Clutter bar functions. Cmd+A is context-sensitive — the playlist
            // window's keyDown monitor intercepts it as Select All when the
            // playlist is key.
            Button(settings.isDoubleSizeMode ? "Normal Size" : "Double Size") {
                dispatcher.perform(WinampKeyBindings.doubleSize.action)
            }
            .keyboardShortcut(WinampKeyBindings.doubleSize.shortcut)

            Button("Always On Top") {
                dispatcher.perform(WinampKeyBindings.alwaysOnTop.action)
            }
            .keyboardShortcut(WinampKeyBindings.alwaysOnTop.shortcut)

            Button("Options Menu") {
                dispatcher.perform(WinampKeyBindings.openOptionsMenu.action)
            }
            .keyboardShortcut(WinampKeyBindings.openOptionsMenu.shortcut)

            Button("Time: \(settings.timeDisplayMode == .elapsed ? "Show Remaining" : "Show Elapsed")") {
                dispatcher.perform(WinampKeyBindings.timeMode.action)
            }
            .keyboardShortcut(WinampKeyBindings.timeMode.shortcut)

            Button("Track Information") {
                dispatcher.perform(WinampKeyBindings.trackInfo.action)
            }
            .keyboardShortcut(WinampKeyBindings.trackInfo.shortcut)

            // `S` and `R` are dispatched by WinampHotkeyMonitor, which consumes
            // the key before menu shortcuts are evaluated. These
            // `.keyboardShortcut`s only surface the bindings in the menu; they
            // never drive the action while a primary window is key.
            Button(audioPlayer.shuffleEnabled ? "Shuffle: On" : "Shuffle: Off") {
                dispatcher.perform(WinampKeyBindings.toggleShuffleHotkey.action)
            }
            .keyboardShortcut(WinampKeyBindings.toggleShuffleHotkey.shortcut)

            Button(audioPlayer.repeatMode.label) {
                dispatcher.perform(WinampKeyBindings.cycleRepeatHotkey.action)
            }
            .keyboardShortcut(WinampKeyBindings.cycleRepeatHotkey.shortcut)

            // Video Window toggle. Plain `V` (Webamp stop) is in the hotkey
            // monitor and `⌘V` is system Paste, so video uses `⌘⇧V`.
            Button(settings.showVideoWindow ? "Hide Video Window" : "Show Video Window") {
                dispatcher.perform(WinampKeyBindings.videoWindow.action)
            }
            .keyboardShortcut(WinampKeyBindings.videoWindow.shortcut)

            Button(settings.showMilkdropWindow ? "Hide Milkdrop" : "Show Milkdrop") {
                dispatcher.perform(WinampKeyBindings.milkdrop.action)
            }
            .keyboardShortcut(WinampKeyBindings.milkdrop.shortcut)
        }

        CommandGroup(replacing: .newItem) {
            Button("Open Files...") {
                dispatcher.perform(WinampKeyBindings.openFiles.action)
            }
            .keyboardShortcut(WinampKeyBindings.openFiles.shortcut)
        }

        // MacAmp has no settings window; hide the empty "Settings…" item.
        CommandGroup(replacing: .appSettings) {}
    }
}
