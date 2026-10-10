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

    /// Counts requests to point the panel at a track, so a slow load that a
    /// later request overtook is dropped instead of applied.
    private var request = 0

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

    /// Load the info for `track`, then present the panel for it, or bring it
    /// forward when it is already open, so the panel never shows a track whose
    /// info is still loading. A nil track describes the playing stream.
    func show(_ track: Track?) {
        request += 1
        let current = request
        Task {
            let info: FileInfo?
            if let track, !track.isStream {
                info = await MetadataLoader.loadFileInfo(from: track.url)
            } else {
                info = nil
            }
            guard current == request else { return }
            settings.trackInfoTrack = track
            settings.trackInfoFileInfo = info
            settings.showTrackInfoDialog = true
            window?.makeKeyAndOrderFront(nil)
        }
    }

    /// Keep the panel one step above the skinned windows, whose level follows
    /// the always-on-top setting.
    func applyWindowLevel(alwaysOnTop: Bool) {
        window?.level = alwaysOnTop
            ? NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            : .floating
    }

    /// Closing drops any load still in flight, so it cannot reopen the panel.
    func windowWillClose(_ notification: Notification) {
        request += 1
        settings.showTrackInfoDialog = false
    }
}
