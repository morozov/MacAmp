import Foundation
import Observation

/// Auto-saves and restores the playlist + current-track marker to a private
/// `playlist.m3u` in the application-support directory (Spec 005).
///
/// - `restoreSnapshot()` is called once at launch before this store is wired
///   up; it produces an `M3UParseResult` that the caller materializes through
///   `AudioPlayer.addEntries`.
/// - The instance observes `AudioPlayer.playlist` and
///   `PlaybackCoordinator.currentTrack`; mutations schedule a debounced
///   trailing-edge save (1 s window). Writes happen atomically off the main
///   actor.
/// - `flushSynchronously()` is invoked from `applicationWillTerminate` to
///   commit any pending debounced write before the process exits.
@MainActor
final class PlaylistStateStore {

    // MARK: - File location

    /// Returns the on-disk path for `playlist.m3u`, creating the parent
    /// directory if needed. Returns nil only if the application-support URL
    /// cannot be resolved (effectively never on a normal install).
    nonisolated static func playlistFileURL() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("MacAmp", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                AppLog.error(.audio, "Failed to create app support dir: \(error)")
                return nil
            }
        }
        return dir.appendingPathComponent("playlist.m3u")
    }

    // MARK: - Restore (static — runs before instance exists)

    /// Synchronously read and parse `playlist.m3u`. Returns nil when the file
    /// is absent, unreadable, or fails to parse (e.g., version mismatch,
    /// missing `#EXTM3U`). On parse failure, the next save trigger will
    /// overwrite the file (per spec restore-caller recovery).
    static func restoreSnapshot() -> M3UParseResult? {
        guard let url = playlistFileURL(),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            return try M3UParser.parse(fileURL: url)
        } catch {
            AppLog.warn(.audio, "playlist.m3u failed to parse (\(error.localizedDescription)); starting empty. Next save will overwrite.")
            return nil
        }
    }

    // MARK: - Instance

    private let audioPlayer: AudioPlayer
    private weak var playbackCoordinator: PlaybackCoordinator?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    private static let debounceInterval: UInt64 = 1_000_000_000  // 1 s in ns

    init(audioPlayer: AudioPlayer, playbackCoordinator: PlaybackCoordinator) {
        self.audioPlayer = audioPlayer
        self.playbackCoordinator = playbackCoordinator
        observe()
    }

    deinit {
        debounceTask?.cancel()
    }

    // MARK: - Observation

    /// Re-armed `withObservationTracking` loop. Each change to either the
    /// playlist or the current track fires `onChange`, which schedules a save
    /// and re-arms the next observation cycle.
    private func observe() {
        withObservationTracking {
            _ = audioPlayer.playlist
            _ = playbackCoordinator?.currentTrack
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.scheduleSave()
                self.observe()
            }
        }
    }

    // MARK: - Save (debounced, atomic, off-main)

    /// Restart the debounce timer; the actual write fires on the trailing edge.
    private func scheduleSave() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceInterval)
            guard !Task.isCancelled, let self else { return }
            let content = await self.snapshotContent()
            await Self.writeAtomically(content)
        }
    }

    /// Block until any pending write has been flushed. Safe to call from
    /// `applicationWillTerminate`; serializes on the main actor and writes
    /// synchronously on the calling thread.
    func flushSynchronously() {
        debounceTask?.cancel()
        debounceTask = nil
        let content = snapshotContentSync()
        Self.writeAtomicallySync(content)
    }

    /// Build the extended-M3U string from current playlist + selection state.
    /// Main-actor read; the write itself runs off-actor.
    private func snapshotContent() async -> String { snapshotContentSync() }

    private func snapshotContentSync() -> String {
        let tracks = audioPlayer.playlist
        let currentIndex: Int?
        if let current = playbackCoordinator?.currentTrack,
           let idx = tracks.firstIndex(where: { $0.id == current.id }) {
            currentIndex = idx
        } else {
            currentIndex = nil
        }
        return M3UWriter.serializeState(tracks: tracks, currentIndex: currentIndex)
    }

    // MARK: - Atomic write helpers (off-actor)

    /// Write `content` to `playlist.m3u` atomically (temp file + rename). The
    /// async variant hops to a detached task so the main actor isn't blocked
    /// during I/O.
    nonisolated private static func writeAtomically(_ content: String) async {
        await Task.detached(priority: .utility) {
            writeAtomicallySync(content)
        }.value
    }

    /// Synchronous variant used by `flushSynchronously()` on app termination.
    nonisolated private static func writeAtomicallySync(_ content: String) {
        guard let url = playlistFileURL() else { return }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try content.write(to: tmp, atomically: false, encoding: .utf8)
            // Atomic rename onto the final path; `replaceItemAt` handles the
            // case where the destination already exists.
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            AppLog.error(.audio, "Failed to write playlist.m3u: \(error)")
            // Best-effort cleanup of the temp file.
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
