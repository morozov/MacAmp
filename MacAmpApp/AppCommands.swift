import SwiftUI
import AppKit

struct AppCommands: Commands {
    @Bindable var dockingController: DockingController
    @Bindable var audioPlayer: AudioPlayer
    @Bindable var settings: AppSettings
    var dispatcher: UserActionDispatcher

    var body: some Commands {
        CommandMenu("Options") {
            Button(dockingController.showMain ? "Hide Main" : "Show Main") {
                dispatcher.perform(WinampKeyBindings.toggleMainWindowAlt.action)
            }
            .keyboardShortcut(WinampKeyBindings.toggleMainWindowAlt.shortcut)

            // Read visibility from `settings` (kept in sync by
            // WindowVisibilityController). `dockingController.panes[…].visible`
            // is no longer updated when toggling through the dispatcher and
            // would drift after the first invocation.
            Button(settings.showPlaylistWindow ? "Hide Playlist" : "Show Playlist") {
                dispatcher.perform(WinampKeyBindings.togglePlaylistWindowAlt.action)
            }
            .keyboardShortcut(WinampKeyBindings.togglePlaylistWindowAlt.shortcut)

            Button(settings.showEqualizerWindow ? "Hide Equalizer" : "Show Equalizer") {
                dispatcher.perform(WinampKeyBindings.toggleEqualizerWindowAlt.action)
            }
            .keyboardShortcut(WinampKeyBindings.toggleEqualizerWindowAlt.shortcut)

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

        CommandGroup(replacing: .appSettings) {
            Button("Preferences...") {
                dispatcher.perform(WinampKeyBindings.preferences.action)
            }
            .keyboardShortcut(WinampKeyBindings.preferences.shortcut)
        }
    }
}
