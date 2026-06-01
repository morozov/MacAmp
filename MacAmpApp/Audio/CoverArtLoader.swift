import Foundation
import AppKit
import AVFoundation
import MediaPlayer

/// Resolves cover art for a local audio file, mirroring mpv's `--cover-art-auto`
/// resolution (`player/external_files.c`, `options/options.c` defaults).
///
/// Layer: Mechanism (pure utility, no state).
///
/// Resolution order:
/// 1. Embedded artwork in the file's common metadata.
/// 2. A sidecar image whose basename matches the audio file (`Song.flac` → `Song.jpg`).
/// 3. A whitelisted directory image (`cover.*`, `folder.*`, …), by mpv's priority order.
///
/// Design mirrors `MetadataLoader`: a nonisolated enum with static async methods,
/// so the filesystem scan and image decode run off the calling actor.
enum CoverArtLoader {

    /// Image extensions mpv treats as cover-art candidates (`image_exts` default).
    static let imageExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "j2k", "jp2", "jpeg", "jpg",
        "jxl", "png", "qoi", "svg", "tga", "tif", "tiff", "webp",
    ]

    /// Sidecar basenames mpv probes when no exact-name match exists
    /// (`cover-art-whitelist` default), in descending priority order.
    static let whitelist: [String] = [
        "AlbumArt", "Album", "cover", "front",
        "AlbumArtSmall", "Folder", ".folder", "thumb",
    ]

    /// Priority assigned to a sidecar whose basename equals the audio file's.
    /// Outranks every whitelist entry so an exact match always wins.
    private static let exactMatchPriority = Int.max

    /// Resolve cover art for a local audio file as a system Now Playing artwork.
    /// Returns `nil` for non-file URLs or when no artwork is found.
    ///
    /// The `MPMediaItemArtwork` is built here, in this nonisolated context, on
    /// purpose: MediaPlayer invokes its request handler on a private background
    /// queue, so the handler must not inherit any actor isolation.
    static func loadCoverArt(for url: URL) async -> MPMediaItemArtwork? {
        guard url.isFileURL else { return nil }

        let image: NSImage?
        if let embedded = await loadEmbeddedArtwork(from: url) {
            image = embedded
        } else {
            image = loadExternalArtwork(for: url)
        }

        guard let image else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    // MARK: - Embedded

    /// Load artwork embedded in the file's common metadata (`.commonIdentifierArtwork`).
    private static func loadEmbeddedArtwork(from url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        do {
            let metadata = try await asset.load(.commonMetadata)
            guard let item = AVMetadataItem.metadataItems(
                from: metadata,
                filteredByIdentifier: .commonIdentifierArtwork
            ).first else { return nil }

            guard let data = try await item.load(.dataValue) else { return nil }
            return NSImage(data: data)
        } catch {
            AppLog.warn(.audio, "Failed to load embedded artwork for \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    // MARK: - External (sidecar / whitelist)

    /// Scan the audio file's directory for a sidecar or whitelisted cover image.
    /// Candidates are scored by mpv's priority order; the highest-priority image
    /// that decodes is returned.
    private static func loadExternalArtwork(for url: URL) -> NSImage? {
        let directory = url.deletingLastPathComponent()
        let audioBasename = url.deletingPathExtension().lastPathComponent

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []  // include dotfiles — the `.folder` whitelist entry is hidden
        ) else { return nil }

        let candidates = entries
            .compactMap { entry -> (priority: Int, url: URL)? in
                guard imageExtensions.contains(entry.pathExtension.lowercased()) else { return nil }
                guard let priority = matchPriority(
                    imageBasename: entry.deletingPathExtension().lastPathComponent,
                    audioBasename: audioBasename
                ) else { return nil }
                return (priority, entry)
            }
            .sorted { $0.priority > $1.priority }

        // mpv hands the chosen path to its decoder with no fallback; we instead try
        // candidates in priority order so an undecodable top pick (e.g. an SVG that
        // NSImage can't render) yields to the next-best image rather than nothing.
        for candidate in candidates {
            if let image = NSImage(contentsOf: candidate.url) {
                return image
            }
        }
        return nil
    }

    /// Priority of an image basename relative to the audio file's basename, or
    /// `nil` when it is neither an exact match nor whitelisted. Comparison is
    /// case-insensitive, matching mpv's `bstrcasecmp` / `test_cover_filename`.
    private static func matchPriority(imageBasename: String, audioBasename: String) -> Int? {
        if imageBasename.caseInsensitiveCompare(audioBasename) == .orderedSame {
            return exactMatchPriority
        }
        if let index = whitelist.firstIndex(where: {
            $0.caseInsensitiveCompare(imageBasename) == .orderedSame
        }) {
            // Earlier whitelist entries rank higher.
            return whitelist.count - index
        }
        return nil
    }
}
