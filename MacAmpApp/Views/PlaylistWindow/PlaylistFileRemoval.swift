import Foundation

enum PlaylistFileRemoval {
    struct Failure: Sendable {
        let url: URL
        let message: String
    }

    struct Outcome: Sendable {
        var removedIDs: Set<UUID> = []
        var failures: [Failure] = []
    }

    static func selectedLocalTracks(in tracks: [Track], indices: Set<Int>) -> [Track] {
        indices.sorted(by: >).compactMap { index in
            guard tracks.indices.contains(index), tracks[index].url.isFileURL else { return nil }
            return tracks[index]
        }
    }

    @concurrent
    static func missingFiles(
        in tracks: [Track],
        canRead: @Sendable (URL) -> Bool = canReadFile
    ) async -> Outcome {
        var outcome = Outcome()
        for track in tracks where track.url.isFileURL && !canRead(track.url) {
            outcome.removedIDs.insert(track.id)
        }
        return outcome
    }

    @concurrent
    static func trashFiles(
        _ tracks: [Track],
        confirmed: Bool,
        trash: @Sendable (URL) throws -> Void = trashFile
    ) async -> Outcome {
        guard confirmed else { return Outcome() }
        var outcome = Outcome()
        var processed: Set<URL> = []
        for track in tracks where track.url.isFileURL {
            let url = track.url.standardizedFileURL
            guard processed.insert(url).inserted else { continue }
            do {
                try trash(url)
                outcome.removedIDs.formUnion(tracks.filter {
                    $0.url.isFileURL && $0.url.standardizedFileURL == url
                }.map(\.id))
            } catch {
                outcome.failures.append(Failure(url: url, message: error.localizedDescription))
            }
        }
        return outcome
    }

    private static func canReadFile(_ url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        try? file.close()
        return true
    }

    static func trashFile(_ url: URL) throws {
        guard !UnitTestSupport.isActive else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
