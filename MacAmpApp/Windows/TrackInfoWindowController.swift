import AppKit
import SwiftUI

/// The File Info panel. Escape closes it, matching the Done button and the
/// titlebar close button.
private final class TrackInfoPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// Hosts `TrackInfoView` in a window of its own: a non-modal utility panel
/// that floats above the skinned windows, leaves them fully interactive, and
/// has its own position independent of theirs.
@MainActor
final class TrackInfoWindowController: NSWindowController, NSWindowDelegate {
    private let settings: AppSettings

    init(audioPlayer: AudioPlayer, playbackCoordinator: PlaybackCoordinator, settings: AppSettings) {
        self.settings = settings

        let panel = TrackInfoPanel(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 320),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "File Info"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.tabbingMode = .disallowed

        super.init(window: panel)

        panel.contentViewController = NSHostingController(
            rootView: TrackInfoView(onDone: { [weak panel] in panel?.close() })
                .environment(audioPlayer)
                .environment(playbackCoordinator)
                .environment(settings)
        )
        panel.delegate = self
        panel.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Present the panel, or bring it forward when it is already open. The
    /// view reads its track from `settings.trackInfoTrack`, so an open panel
    /// reloads itself when the caller points it at a different track.
    func show() {
        settings.showTrackInfoDialog = true
        window?.makeKeyAndOrderFront(nil)
    }

    /// Keep the panel one step above the skinned windows, whose level follows
    /// the always-on-top setting.
    func applyWindowLevel(alwaysOnTop: Bool) {
        window?.level = alwaysOnTop
            ? NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            : .floating
    }

    func windowWillClose(_ notification: Notification) {
        settings.showTrackInfoDialog = false
    }
}
