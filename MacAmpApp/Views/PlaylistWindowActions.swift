import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class PlaylistWindowActions: NSObject {
    static let shared = PlaylistWindowActions()

    var selectedIndices: Set<Int> = []
    weak var radioLibrary: RadioStationLibrary?
    weak var playbackCoordinator: PlaybackCoordinator?
    private var loadListGeneration: UInt64 = 0

    private func showAlert(_ title: String, _ message: String) {
        WinampAlertHelper.showInfo(title: title, message: message)
    }

    private func showErrorAlert(_ title: String, error: Error) {
        WinampAlertHelper.showError(title: title, message: error.localizedDescription)
    }

    // MARK: - Unified Auto-Play

    /// Auto-play the first playlist track via coordinator if the playlist was previously empty.
    /// Single source of truth for all auto-play paths — eliminates duplication.
    private func autoPlayFirstTrack(
        audioPlayer: AudioPlayer,
        coordinator: PlaybackCoordinator?,
        wasEmpty: Bool
    ) async {
        guard wasEmpty, let coordinator, let firstTrack = audioPlayer.playlist.first else { return }
        await coordinator.play(track: firstTrack)
    }

    // MARK: - Unified M3U Materialization

    /// Spec 005: route a parsed M3U through the same materializer used by
    /// auto-restore. `.cue` URLs inside the M3U are expanded by re-entering
    /// `parseAndAddCue` (failures surface loudly — the user explicitly
    /// referenced the sheet). Returns the count of materialized entries so
    /// the caller can map `currentIndex` against the resulting playlist.
    @discardableResult
    private func materializeM3U(_ parsed: M3UParseResult, audioPlayer: AudioPlayer) async -> Int {
        var added = 0
        for entry in parsed.entries {
            if entry.cueSlice == nil
                && !entry.isRemoteStream
                && entry.url.pathExtension.lowercased() == "cue" {
                let before = audioPlayer.playlist.count
                await parseAndAddCue(entry.url, audioPlayer: audioPlayer, reportFailureLoudly: true)
                added += audioPlayer.playlist.count - before
            } else {
                let before = audioPlayer.playlist.count
                audioPlayer.addEntries([entry])
                added += audioPlayer.playlist.count - before
            }
        }
        return added
    }

    /// Load List apply: stale-generation check, clear, materialize, then apply
    /// the parsed file's `currentIndex` per Spec 005 caller-responsibilities
    /// table. Returns false if a newer Load List superseded this one.
    private func applyLoadedPlaylist(
        _ parsed: M3UParseResult,
        expectedGeneration: UInt64,
        audioPlayer: AudioPlayer,
        coordinator: PlaybackCoordinator?
    ) async -> Bool {
        guard loadListGeneration == expectedGeneration else { return false }
        audioPlayer.clearPlaylist()
        await materializeM3U(parsed, audioPlayer: audioPlayer)
        applyCurrentIndex(parsed.currentIndex, audioPlayer: audioPlayer, coordinator: coordinator)
        return true
    }

    /// Apply the parsed file's `currentIndex` against the current playlist:
    /// when in bounds, select that track without starting playback. No-op when
    /// nil or out-of-bounds.
    private func applyCurrentIndex(
        _ index: Int?,
        audioPlayer: AudioPlayer,
        coordinator: PlaybackCoordinator?
    ) {
        guard let coordinator,
              let index,
              audioPlayer.playlist.indices.contains(index) else { return }
        coordinator.selectTrack(audioPlayer.playlist[index])
    }

    // MARK: - Add Files Panel

    func presentAddFilesPanel(audioPlayer: AudioPlayer, playbackCoordinator: PlaybackCoordinator? = nil) {
        let openPanel = NSOpenPanel()
        let m3uType = UTType(filenameExtension: "m3u") ?? .plainText
        let m3u8Type = UTType(filenameExtension: "m3u8") ?? .plainText
        let cueType = UTType(filenameExtension: "cue") ?? .plainText
        openPanel.allowedContentTypes = [.audio, m3uType, m3u8Type, cueType, .movie]
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.title = "Add Files to Playlist"
        openPanel.message = "Select audio files, video files, or playlists"
        runOpenPanel(openPanel, audioPlayer: audioPlayer, playbackCoordinator: playbackCoordinator)
    }

    func presentAddDirectoryPanel(audioPlayer: AudioPlayer, playbackCoordinator: PlaybackCoordinator? = nil) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = true
        openPanel.title = "Add Folder to Playlist"
        openPanel.message = "Select a folder of audio files"
        runOpenPanel(openPanel, audioPlayer: audioPlayer, playbackCoordinator: playbackCoordinator)
    }

    private func runOpenPanel(
        _ openPanel: NSOpenPanel,
        audioPlayer: AudioPlayer,
        playbackCoordinator: PlaybackCoordinator?
    ) {
        openPanel.begin { response in
            guard response == .OK else { return }
            let urls = openPanel.urls
            Task { @MainActor [weak self, urls, audioPlayer, playbackCoordinator] in
                guard let self else { return }
                let coordinator = playbackCoordinator ?? self.playbackCoordinator
                let wasEmpty = audioPlayer.playlist.isEmpty

                let hint = await self.handleSelectedURLs(urls, audioPlayer: audioPlayer)

                // Spec 005: when N == 0 and the first M3U carried a
                // currentIndex, restore that selection without auto-play.
                // Otherwise fall through to the existing auto-play-first-track
                // behavior (gated on wasEmpty as before).
                if wasEmpty, let hint, let coordinator,
                   audioPlayer.playlist.indices.contains(hint.absoluteIndex) {
                    coordinator.selectTrack(audioPlayer.playlist[hint.absoluteIndex])
                } else {
                    await self.autoPlayFirstTrack(
                        audioPlayer: audioPlayer,
                        coordinator: coordinator,
                        wasEmpty: wasEmpty
                    )
                }
            }
        }
    }

    // MARK: - File Handling (async — awaits M3U parsing)

    /// Hint surfaced by `handleSelectedURLs` for the caller's post-load decision.
    /// Captures the absolute playlist index that the first processed M3U's
    /// `#EXTMACAMP-CURRENT` resolves to (Spec 005, caller-responsibilities table).
    struct SelectionHint {
        let absoluteIndex: Int
    }

    func handleSelectedURLs(
        _ urls: [URL],
        audioPlayer: AudioPlayer,
        at insertIndex: Int? = nil
    ) async -> SelectionHint? {
        let appendStart = audioPlayer.playlist.count
        var firstHint: SelectionHint?
        // Expand any directories upfront, off-main, so a large drop doesn't
        // freeze the UI on the FileManager enumeration.
        let resolved = await Task.detached(priority: .userInitiated) {
            Self.expandDirectories(urls)
        }.value
        for url in resolved {
            let ext = url.pathExtension.lowercased()
            if ext == "m3u" || ext == "m3u8" {
                let offset = audioPlayer.playlist.count
                if let parsed = await parseAndAddM3U(url, audioPlayer: audioPlayer),
                   firstHint == nil,
                   let ci = parsed.currentIndex,
                   audioPlayer.playlist.indices.contains(offset + ci) {
                    firstHint = SelectionHint(absoluteIndex: offset + ci)
                }
            } else if ext == "cue" {
                await parseAndAddCue(url, audioPlayer: audioPlayer, reportFailureLoudly: true)
            } else if let sidecar = CueParser.sidecarCueURL(for: url) {
                // Opportunistic sidecar: a sidecar parse failure or a FILE-directive
                // mismatch (CUE points at a different audio file) does NOT block the
                // audio file from being added the normal way. Direct CUE opens fail
                // loudly; sidecar misses fall back silently.
                let added = await parseAndAddCue(
                    sidecar,
                    audioPlayer: audioPlayer,
                    reportFailureLoudly: false,
                    expectedAudioURL: url
                )
                if !added {
                    audioPlayer.addTrack(url: url)
                }
            } else {
                audioPlayer.addTrack(url: url)
            }
        }

        // Each branch above appends; lift the new tail to the requested
        // position so a single moveTracks captures the entire batch (rather
        // than threading an `at:` cursor through every add path).
        if let insertIndex,
           insertIndex < appendStart,
           audioPlayer.playlist.count > appendStart {
            let appended = appendStart..<audioPlayer.playlist.count
            audioPlayer.moveTracks(from: appended, to: insertIndex)
            // Re-base the M3U currentIndex hint into the post-move playlist.
            if let hint = firstHint {
                let shift = insertIndex - appendStart
                firstHint = SelectionHint(absoluteIndex: hint.absoluteIndex + shift)
            }
        }

        return firstHint
    }

    /// Parse M3U off main actor, materialize on main actor. Returns the parse
    /// result so callers can apply `currentIndex` per Spec 005, or nil on
    /// parse failure (alert already shown).
    private func parseAndAddM3U(_ url: URL, audioPlayer: AudioPlayer) async -> M3UParseResult? {
        let result: Result<M3UParseResult, Error> = await Task.detached(priority: .userInitiated) {
            Result { try M3UParser.parse(fileURL: url) }
        }.value

        switch result {
        case .success(let parsed):
            await materializeM3U(parsed, audioPlayer: audioPlayer)
            return parsed
        case .failure(let error):
            showErrorAlert("Failed to Load M3U Playlist", error: error)
            return nil
        }
    }

    /// Parse a CUE sheet and add its tracks to the playlist.
    /// - Parameters:
    ///   - reportFailureLoudly: true for direct `.cue` opens, false for sidecar discovery.
    ///   - expectedAudioURL: when non-nil (sidecar path), the CUE's `FILE` directive
    ///     MUST resolve to this audio file; on mismatch the sheet is ignored
    ///     (debug-log only) and `false` is returned so the caller adds the original
    ///     audio file normally.
    /// - Returns: true if tracks were added, false on parse failure, FILE mismatch,
    ///   or when the sheet was already in the playlist.
    @discardableResult
    private func parseAndAddCue(
        _ url: URL,
        audioPlayer: AudioPlayer,
        reportFailureLoudly: Bool,
        expectedAudioURL: URL? = nil
    ) async -> Bool {
        let result: Result<CueParseResult, Error>
        do {
            let parsed = try await CueParser.parse(fileURL: url)
            result = .success(parsed)
        } catch {
            result = .failure(error)
        }

        switch result {
        case .success(let parsed):
            if let expectedAudioURL,
               parsed.audioFileURL.standardizedFileURL != expectedAudioURL.standardizedFileURL {
                AppLog.debug(
                    .audio,
                    "Ignoring sidecar CUE \(url.lastPathComponent): FILE resolves to '\(parsed.audioFileURL.lastPathComponent)', expected '\(expectedAudioURL.lastPathComponent)'"
                )
                return false
            }
            return audioPlayer.addCueTracks(parsed.tracks)
        case .failure(let error):
            if reportFailureLoudly {
                showErrorAlert("Failed to Load CUE Sheet", error: error)
            } else {
                AppLog.debug(.audio, "Ignoring sidecar CUE \(url.lastPathComponent): \(error.localizedDescription)")
            }
            return false
        }
    }

    // MARK: - Directory Expansion

    /// Walk any directories in `urls` and replace them with their contained
    /// audio / playlist / CUE files. Non-directory URLs pass through in
    /// order; per-directory contents are appended sorted by Finder-style
    /// localized name so the playlist order is predictable. Nonisolated so
    /// it can run off the main actor.
    nonisolated static func expandDirectories(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            if isDirectory(url) {
                result.append(contentsOf: enumerateMediaFiles(in: url))
            } else {
                result.append(url)
            }
        }
        return result
    }

    nonisolated private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    nonisolated private static func enumerateMediaFiles(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [URL] = []
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }

            let ext = file.pathExtension.lowercased()
            if ext == "m3u" || ext == "m3u8" || ext == "cue" {
                results.append(file)
            } else if let type = values.contentType,
                      type.conforms(to: .audio) || type.conforms(to: .movie) {
                results.append(file)
            }
        }

        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: - Add Menu Actions

    @objc func addURL(_ sender: NSMenuItem) {
        guard let audioPlayer = sender.representedObject as? AudioPlayer else {
            showAlert("Error", "Audio player not available")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Add Internet Radio Station"
        alert.informativeText = "Enter the stream URL (HTTP or HTTPS):"

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "http://stream.example.com/radio.mp3"
        input.usesSingleLineMode = true
        input.lineBreakMode = .byClipping
        input.cell?.wraps = false
        input.cell?.isScrollable = true
        alert.accessoryView = input

        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            let urlString = input.stringValue.trimmingCharacters(in: .whitespaces)

            guard !urlString.isEmpty else {
                showAlert("Invalid URL", "Please enter a valid URL")
                return
            }

            guard let url = URL(string: urlString),
                  url.scheme == "http" || url.scheme == "https" else {
                showAlert("Invalid URL", "URL must start with http:// or https://")
                return
            }

            let stationName = url.host ?? url.lastPathComponent
            let streamTrack = Track(
                url: url,
                title: stationName,
                artist: "Internet Radio",
                duration: 0.0
            )

            audioPlayer.addStreamTrack(streamTrack)

            showAlert("Stream Added", "Added '\(stationName)' to playlist.\n\nClick to play!")
        }
    }

    @objc func addDirectory(_ sender: NSMenuItem) {
        guard let audioPlayer = sender.representedObject as? AudioPlayer else { return }
        presentAddDirectoryPanel(audioPlayer: audioPlayer, playbackCoordinator: playbackCoordinator)
    }

    @objc func addFile(_ sender: NSMenuItem) {
        guard let audioPlayer = sender.representedObject as? AudioPlayer else {
            return
        }
        presentAddFilesPanel(audioPlayer: audioPlayer, playbackCoordinator: playbackCoordinator)
    }

    // MARK: - Remove Menu Actions

    @objc func removeSelected(_ sender: NSMenuItem) {
        guard let audioPlayer = sender.representedObject as? AudioPlayer else {
            return
        }

        let indices = PlaylistWindowActions.shared.selectedIndices
        if indices.isEmpty {
            showAlert("Remove Selected", "No tracks selected")
        } else {
            for index in indices.sorted().reversed() {
                audioPlayer.removeTrack(at: index)
            }
            PlaylistWindowActions.shared.selectedIndices = []
        }
    }

    @objc func cropPlaylist(_ sender: NSMenuItem) {
        guard let audioPlayer = sender.representedObject as? AudioPlayer else {
            return
        }

        let indices = PlaylistWindowActions.shared.selectedIndices
        if indices.isEmpty {
            showAlert("Crop Playlist", "No tracks selected. Select tracks to keep, then crop.")
        } else {
            let validIndices = indices.sorted().filter { $0 < audioPlayer.playlist.count }
            let selectedTracks = validIndices.map { audioPlayer.playlist[$0] }
            audioPlayer.replacePlaylist(with: selectedTracks)
            PlaylistWindowActions.shared.selectedIndices = []
        }
    }

    @objc func removeAll(_ sender: NSMenuItem) {
        guard let audioPlayer = sender.representedObject as? AudioPlayer else {
            return
        }
        audioPlayer.clearPlaylist()
    }

    @objc func removeMisc(_ sender: NSMenuItem) {
        showAlert("Remove Misc", "Not supported yet")
    }

    // MARK: - Misc Menu Actions

    @objc func sortList(_ sender: NSMenuItem) {
        showAlert("Sort List", "Not supported yet")
    }

    @objc func fileInfo(_ sender: NSMenuItem) {
        showAlert("File Info", "Not supported yet")
    }

    @objc func miscOptions(_ sender: NSMenuItem) {
        showAlert("Misc Options", "Not supported yet")
    }

    // MARK: - List Operations

    @objc func newList(_ sender: NSMenuItem) {
        guard let audioPlayer = sender.representedObject as? AudioPlayer else { return }
        audioPlayer.clearPlaylist()
    }

    @objc func saveList(_ sender: NSMenuItem) {
        guard let audioPlayer = sender.representedObject as? AudioPlayer else { return }
        guard !audioPlayer.playlist.isEmpty else {
            showAlert("Save List", "Playlist is empty")
            return
        }

        // Warn if the playlist contains CUE-derived entries — M3U cannot represent
        // slicing, so on reload the per-URL dedup collapses sibling slices to one row.
        if audioPlayer.playlist.contains(where: { $0.isCueSlice }) {
            let alert = NSAlert()
            alert.messageText = "Save with CUE slicing loss?"
            alert.informativeText = "This playlist contains CUE-sliced tracks. M3U cannot represent CUE slicing — on reload, sliced tracks will collapse back to the underlying audio file."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Save Anyway")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn {
                return
            }
        }

        let savePanel = NSSavePanel()
        let m3uSaveType = UTType(filenameExtension: "m3u") ?? .plainText
        savePanel.allowedContentTypes = [m3uSaveType]
        savePanel.nameFieldStringValue = "playlist.m3u"
        savePanel.title = "Save Playlist"

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                let tracks = audioPlayer.playlist
                Task.detached(priority: .userInitiated) {
                    do {
                        try M3UWriter.write(tracks: tracks, to: url)
                    } catch {
                        await MainActor.run {
                            self.showErrorAlert("Failed to Save Playlist", error: error)
                        }
                    }
                }
            }
        }
    }

    @objc func loadList(_ sender: NSMenuItem) {
        guard let audioPlayer = sender.representedObject as? AudioPlayer else { return }

        let m3uType = UTType(filenameExtension: "m3u") ?? .plainText
        let m3u8Type = UTType(filenameExtension: "m3u8") ?? .plainText

        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [m3uType, m3u8Type]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.title = "Load Playlist"
        openPanel.message = "Select an M3U playlist file"

        let coordinator = playbackCoordinator
        openPanel.begin { response in
            if response == .OK, let url = openPanel.url {
                self.loadListGeneration &+= 1
                let expectedGeneration = self.loadListGeneration
                Task.detached(priority: .userInitiated) {
                    let result = Result { try M3UParser.parse(fileURL: url) }

                    switch result {
                    case .success(let parsed):
                        let applied = await self.applyLoadedPlaylist(
                            parsed,
                            expectedGeneration: expectedGeneration,
                            audioPlayer: audioPlayer,
                            coordinator: coordinator
                        )
                        // Spec 005: auto-play first track iff currentIndex was
                        // absent (currentIndex apply already happened above and
                        // is the dominant signal when present).
                        if applied, parsed.currentIndex == nil {
                            await self.autoPlayFirstTrack(
                                audioPlayer: audioPlayer,
                                coordinator: coordinator,
                                wasEmpty: true  // Always true — we just cleared
                            )
                        }
                    case .failure(let error):
                        await MainActor.run {
                            self.showErrorAlert("Failed to Load Playlist", error: error)
                        }
                    }
                }
            }
        }
    }
}
