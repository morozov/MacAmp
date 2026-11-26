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
    private let audioPlayer: AudioPlayer
    private var session = PlaylistFileInfoSession()

    init(audioPlayer: AudioPlayer, playbackCoordinator: PlaybackCoordinator, settings: AppSettings) {
        self.settings = settings
        self.audioPlayer = audioPlayer

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
            rootView: TrackInfoView(
                onDone: { [weak self] in self?.finishEntry() },
                onSelect: { [weak self] track in
                    self?.session.cancel()
                    self?.present(track, orderFront: false)
                }
            )
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

    /// Present the panel for `track`, or bring it forward when it is already
    /// open. A nil track describes the playing stream.
    func show(_ track: Track?) {
        session.cancel()
        present(track, orderFront: true)
    }

    func showSelection(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        session.start(tracks)
        showNextEntry()
    }

    private func finishEntry() {
        guard session.canFinish else { return }
        if session.isSelecting {
            showNextEntry()
        } else {
            window?.close()
        }
    }

    private func showNextEntry() {
        switch session.advance(in: audioPlayer.playlist) {
        case .waiting: return
        case .close:
            window?.close()
        case .show(let track):
            present(track, orderFront: true)
        }
    }

    /// Load the info for `track`, then point the panel at it, so the panel
    /// never shows a track whose info is still loading. Stepping to a track
    /// of the file already shown, such as a sibling CUE track, reuses that
    /// file's info.
    private func present(_ track: Track?, orderFront: Bool) {
        let current = session.beginRequest()
        Task {
            let info: FileInfo?
            if let track, track.url.isFileURL {
                if !orderFront, track.url == settings.trackInfoTrack?.url,
                   let loaded = settings.trackInfoFileInfo {
                    info = loaded
                } else {
                    info = await MetadataLoader.loadFileInfo(from: track.url)
                }
            } else {
                info = nil
            }
            let resolvedTrack: Track?
            switch session.completeRequest(current, track: track, in: audioPlayer.playlist) {
            case .superseded: return
            case .skip:
                showNextEntry()
                return
            case .reload(let latest):
                present(latest, orderFront: orderFront)
                return
            case .present(let latest):
                resolvedTrack = latest
            }
            settings.trackInfoTrack = resolvedTrack
            settings.trackInfoFileInfo = info
            if orderFront {
                settings.showTrackInfoDialog = true
                window?.makeKeyAndOrderFront(nil)
            }
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
        session.cancel()
        settings.showTrackInfoDialog = false
    }
}
