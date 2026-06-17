import AppKit

/// Routes files opened from outside the app — Finder double-click, "Open With",
/// or a drag onto the app icon — to the right subsystem by extension:
/// skins install and apply, EQ presets import, and everything else (audio,
/// video, M3U/M3U8/PLS playlists, cue sheets, folders) is added to the playlist.
///
/// `AppDelegate` receives the open event from AppKit and forwards here. The
/// router's collaborators are wired by `MacAmpApp.init`; open events that arrive
/// before that wiring (cold launch) are queued and flushed by `configure`.
@MainActor
final class FileOpenRouter {
    static let shared = FileOpenRouter()
    private init() {}

    private weak var audioPlayer: AudioPlayer?
    private weak var playbackCoordinator: PlaybackCoordinator?
    private weak var skinManager: SkinManager?
    private var pending: [URL] = []
    private var isConfigured = false

    /// Wire the collaborators and drain any URLs received before now.
    func configure(audioPlayer: AudioPlayer, playbackCoordinator: PlaybackCoordinator, skinManager: SkinManager) {
        self.audioPlayer = audioPlayer
        self.playbackCoordinator = playbackCoordinator
        self.skinManager = skinManager
        isConfigured = true
        guard !pending.isEmpty else { return }
        let queued = pending
        pending.removeAll()
        open(queued)
    }

    /// Route opened URLs. Non-file URLs (e.g. the `macamp:` scheme) are ignored.
    func open(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        guard isConfigured, let audioPlayer, let skinManager else {
            pending.append(contentsOf: files)
            return
        }

        var media: [URL] = []
        for url in files {
            switch url.pathExtension.lowercased() {
            case "wsz":
                Task { await skinManager.importSkin(from: url) }
            case "eqf":
                audioPlayer.importEqfPreset(from: url)
            default:
                media.append(url)
            }
        }

        guard !media.isEmpty else { return }
        let coordinator = playbackCoordinator
        Task {
            await PlaylistWindowActions.shared.openExternalURLs(
                media,
                audioPlayer: audioPlayer,
                playbackCoordinator: coordinator
            )
        }
    }
}

/// Minimal app delegate whose sole job is to deliver Launch Services open
/// events to `FileOpenRouter`. Installed via `@NSApplicationDelegateAdaptor`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            FileOpenRouter.shared.open(urls)
        }
    }
}
