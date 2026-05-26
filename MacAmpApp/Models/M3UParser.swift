import Foundation

/// Errors that can occur during M3U parsing
enum M3UParseError: Error, LocalizedError {
    case fileNotFound
    case encodingError
    case emptyPlaylist
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "M3U file not found"
        case .encodingError:
            return "Unable to read M3U file (encoding error)"
        case .emptyPlaylist:
            return "M3U playlist is empty"
        case .unsupportedVersion(let n):
            return "Unsupported MacAmp state-file version: \(n)"
        }
    }
}

/// Result of parsing an M3U (or extended state-file M3U).
///
/// `version` and `currentIndex` come from MacAmp-private `#EXTMACAMP-VERSION`
/// and `#EXTMACAMP-CURRENT` directives; both are nil for vanilla M3U files.
struct M3UParseResult: Equatable {
    var version: Int?
    var currentIndex: Int?
    var entries: [M3UEntry]
}

/// Parser for M3U / M3U8 playlist files, including the MacAmp extended-state
/// directives (`#EXTMACAMP-VERSION`, `#EXTMACAMP-CURRENT`, `#EXTMACAMP-CUE`).
/// Vanilla M3U files parse identically to before; the extension is additive.
struct M3UParser {
    /// Highest `#EXTMACAMP-VERSION` this parser understands.
    static let supportedExtendedVersion: Int = 1

    /// Parse an M3U file from disk
    static func parse(fileURL: URL) throws -> M3UParseResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw M3UParseError.fileNotFound
        }

        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw M3UParseError.encodingError
        }

        return try parse(content: content, relativeTo: fileURL)
    }

    /// Parse M3U content from a string
    static func parse(content: String, relativeTo baseURL: URL? = nil) throws -> M3UParseResult {
        var entries: [M3UEntry] = []
        var version: Int?
        var currentIndex: Int?
        let lines = content.components(separatedBy: .newlines)

        var currentTitle: String?
        var currentDuration: Int?
        var currentSlice: CueSlice?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines
            guard !trimmed.isEmpty else { continue }

            // Directives (and comments)
            if trimmed.hasPrefix("#") {
                if trimmed.hasPrefix("#EXTINF:") {
                    // #EXTINF:duration,title
                    let parts = trimmed.dropFirst(8).components(separatedBy: ",")
                    if let durationStr = parts.first?.trimmingCharacters(in: .whitespaces),
                       let duration = Int(durationStr) {
                        currentDuration = duration
                    }
                    if parts.count > 1 {
                        currentTitle = parts.dropFirst().joined(separator: ",").trimmingCharacters(in: .whitespaces)
                    }
                } else if trimmed.hasPrefix("#EXTMACAMP-VERSION:") {
                    let raw = trimmed.dropFirst("#EXTMACAMP-VERSION:".count).trimmingCharacters(in: .whitespaces)
                    if let n = Int(raw) {
                        version = n
                        if n != Self.supportedExtendedVersion {
                            throw M3UParseError.unsupportedVersion(n)
                        }
                    }
                } else if trimmed.hasPrefix("#EXTMACAMP-CURRENT:") {
                    let raw = trimmed.dropFirst("#EXTMACAMP-CURRENT:".count).trimmingCharacters(in: .whitespaces)
                    if let k = Int(raw), k >= 0 {
                        currentIndex = k
                    }
                } else if trimmed.hasPrefix("#EXTMACAMP-CUE:") {
                    let payload = String(trimmed.dropFirst("#EXTMACAMP-CUE:".count))
                    currentSlice = parseSliceDirective(payload: payload, baseURL: baseURL)
                }
                // Other comments (including #EXTM3U header) are ignored.
                continue
            }

            // URL/path line
            if let url = resolveURL(trimmed, relativeTo: baseURL) {
                let entry = M3UEntry(
                    url: url,
                    title: currentTitle,
                    duration: currentDuration,
                    cueSlice: currentSlice
                )
                entries.append(entry)

                // Reset per-entry accumulators
                currentTitle = nil
                currentDuration = nil
                currentSlice = nil
            }
        }

        guard !entries.isEmpty else {
            throw M3UParseError.emptyPlaylist
        }

        return M3UParseResult(version: version, currentIndex: currentIndex, entries: entries)
    }

    // MARK: - Slice directive parsing

    /// Parse `#EXTMACAMP-CUE:start=<s>,duration=<s>,sheet=<path>` payload.
    /// Returns nil if any required key is missing or malformed.
    private static func parseSliceDirective(payload: String, baseURL: URL?) -> CueSlice? {
        var keys: [String: String] = [:]
        for chunk in payload.split(separator: ",") {
            let pair = chunk.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces)
            let raw = pair[1].trimmingCharacters(in: .whitespaces)
            // Percent-decode the value to recover any `,` or `=` the writer escaped.
            keys[key] = raw.removingPercentEncoding ?? raw
        }

        guard let startStr = keys["start"], let start = Double(startStr),
              let durStr = keys["duration"], let dur = Double(durStr),
              let sheetStr = keys["sheet"] else {
            return nil
        }

        let sheetURL: URL
        if let resolved = resolveURL(sheetStr, relativeTo: baseURL) {
            sheetURL = resolved
        } else {
            sheetURL = URL(fileURLWithPath: sheetStr)
        }

        return CueSlice(startTime: start, duration: dur, cueSheetURL: sheetURL)
    }

    /// Resolve a URL string to an absolute URL
    /// Handles HTTP/HTTPS URLs, absolute file paths, relative paths, and Windows paths
    private static func resolveURL(_ urlString: String, relativeTo baseURL: URL?) -> URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)

        // Handle HTTP/HTTPS URLs (internet radio streams)
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return URL(string: trimmed)
        }

        // Handle absolute file paths (Unix-style)
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }

        // Handle Windows absolute paths (C:\, D:\, etc.)
        if trimmed.count > 2 && trimmed[trimmed.index(trimmed.startIndex, offsetBy: 1)] == ":" {
            // Convert Windows path to Unix path (basic conversion)
            let unixPath = trimmed.replacingOccurrences(of: "\\", with: "/")
            return URL(fileURLWithPath: unixPath)
        }

        // Handle relative paths
        if let base = baseURL {
            // Get the directory containing the M3U file
            let baseDir = base.deletingLastPathComponent()
            // Resolve relative path from M3U directory
            return URL(fileURLWithPath: trimmed, relativeTo: baseDir).standardized
        }

        // Fallback: try as file URL
        return URL(fileURLWithPath: trimmed)
    }
}

// MARK: - M3U Writer

struct M3UWriter {
    /// Write a vanilla, portable M3U file (used by user-invoked `Save List`).
    /// CUE-derived tracks write one EXTINF line per slice with the shared underlying URL.
    /// M3U has no representation for an in-file offset, so on reload via a vanilla M3U
    /// reader the per-URL dedup collapses sibling slices back to a single whole-file entry.
    /// MacAmp's extended reader preserves slicing only when the file uses `#EXTMACAMP-CUE`
    /// directives (see `M3UStateWriter`).
    static func write(tracks: [Track], to url: URL) throws {
        var lines = ["#EXTM3U"]
        for track in tracks {
            lines.append(extInfLine(for: track))
            lines.append(urlLine(for: track))
        }
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Serialize the playlist as an extended M3U with `#EXTMACAMP-*` directives.
    /// Used by `PlaylistStateStore` for the auto-saved `playlist.m3u`.
    static func serializeState(tracks: [Track], currentIndex: Int?) -> String {
        var lines: [String] = ["#EXTM3U"]
        lines.append("#EXTMACAMP-VERSION:\(M3UParser.supportedExtendedVersion)")
        if let k = currentIndex, k >= 0, k < tracks.count {
            lines.append("#EXTMACAMP-CURRENT:\(k)")
        }
        for track in tracks {
            lines.append(extInfLine(for: track))
            if let slice = track.cueSlice {
                lines.append(cueDirective(for: slice))
            }
            lines.append(urlLine(for: track))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Line helpers

    private static func extInfLine(for track: Track) -> String {
        let duration = track.isStream ? -1 : Int(track.duration)
        let displayTitle = track.artist.isEmpty || track.artist == "Unknown Artist"
            ? track.title
            : "\(track.artist) - \(track.title)"
        return "#EXTINF:\(duration),\(displayTitle)"
    }

    private static func urlLine(for track: Track) -> String {
        return track.isStream ? track.url.absoluteString : track.url.path
    }

    private static func cueDirective(for slice: CueSlice) -> String {
        // `,` and `=` in the sheet path would break the simple key=value,... grammar
        // — percent-encode just those two characters so the parser can recover them.
        let sheetPath = slice.cueSheetURL.path
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: ",", with: "%2C")
            .replacingOccurrences(of: "=", with: "%3D")
        return "#EXTMACAMP-CUE:start=\(slice.startTime),duration=\(slice.duration),sheet=\(sheetPath)"
    }
}
