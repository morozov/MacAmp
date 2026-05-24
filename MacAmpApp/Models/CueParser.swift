import Foundation
import AVFoundation

/// Errors that can occur during CUE parsing.
enum CueParseError: Error, LocalizedError {
    case fileNotFound
    case encodingError
    case noFileDirective
    case multipleFileDirectives
    case missingReferencedFile(URL)
    case noAudioTracks
    case malformedIndex(line: String)
    case duplicateIndex(trackNumber: Int)

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "CUE sheet not found"
        case .encodingError:
            return "Unable to decode the CUE sheet (unknown text encoding)"
        case .noFileDirective:
            return "CUE sheet has no FILE directive"
        case .multipleFileDirectives:
            return "CUE sheets that reference more than one audio file are not supported"
        case .missingReferencedFile(let url):
            return "Audio file referenced by the CUE sheet was not found: \(url.lastPathComponent)"
        case .noAudioTracks:
            return "CUE sheet has no AUDIO tracks"
        case .malformedIndex(let line):
            return "Malformed INDEX line in CUE sheet: \(line)"
        case .duplicateIndex(let n):
            return "CUE sheet has duplicate INDEX 01 values at track \(n)"
        }
    }
}

/// Result of parsing a CUE sheet: the underlying audio file and the materialized track list.
struct CueParseResult {
    let audioFileURL: URL
    let sheetURL: URL
    let tracks: [Track]
}

/// Parser for sidecar `.cue` files.
///
/// Supports a small directive subset: FILE, TRACK ... AUDIO, TITLE, PERFORMER,
/// INDEX 00, INDEX 01. Other directives (REM, CATALOG, ISRC, FLAGS, PREGAP,
/// POSTGAP, CDTEXTFILE, ...) are silently ignored.
///
/// Tolerances: encoding fallback (UTF-16 BOM → UTF-8 → Shift-JIS → Windows-1252),
/// BOM, CRLF/LF/CR, quoted/unquoted values, `MM:SS` index without frames (treated
/// as `MM:SS:00`).
///
/// Rejections: zero AUDIO tracks, more than one FILE directive, missing referenced
/// audio file, duplicate INDEX 01 (within a track or shared by two AUDIO tracks).
enum CueParser {

    // MARK: - Public Entry Points

    /// Parse a CUE file from disk. Loads the referenced audio file's duration to
    /// compute the last slice's length.
    static func parse(fileURL: URL) async throws -> CueParseResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CueParseError.fileNotFound
        }
        let data = try Data(contentsOf: fileURL)
        let content = try decode(data: data)
        return try await parse(content: content, sheetURL: fileURL)
    }

    /// Parse CUE content from an already-decoded string. Public for testing.
    static func parse(content: String, sheetURL: URL) async throws -> CueParseResult {
        var fileDirectivePath: String?
        var sheetTitle: String?
        var sheetPerformer: String?

        struct RawTrack {
            var number: Int
            var isAudio: Bool
            var title: String?
            var performer: String?
            var index01: Double?      // seconds; required for AUDIO tracks
            var index00: Double?      // pregap start; informational
            var sourceLine: String?   // for error messages
        }

        var rawTracks: [RawTrack] = []
        var current: RawTrack?

        // Split on any Unicode newline scalar. `String.split(whereSeparator:)` would
        // operate on Character (grapheme cluster) granularity, and Unicode treats
        // "\r\n" as a single grapheme — so a CRLF-terminated file (the common
        // Windows-tool output) would collapse into a single "line" and the FILE
        // directive would never be recognized.
        let lines = content.components(separatedBy: .newlines)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let tokens = tokenize(line)
            guard let directive = tokens.first?.uppercased() else { continue }

            switch directive {
            case "FILE":
                guard fileDirectivePath == nil else {
                    throw CueParseError.multipleFileDirectives
                }
                // FILE "path" TYPE — path is the second token.
                if tokens.count >= 2 {
                    fileDirectivePath = tokens[1]
                }

            case "TRACK":
                // TRACK NN TYPE
                if let existing = current {
                    rawTracks.append(existing)
                }
                let number = tokens.count >= 2 ? Int(tokens[1]) ?? (rawTracks.count + 1) : (rawTracks.count + 1)
                let type = tokens.count >= 3 ? tokens[2].uppercased() : "AUDIO"
                current = RawTrack(
                    number: number,
                    isAudio: type == "AUDIO",
                    title: nil,
                    performer: nil,
                    index01: nil,
                    index00: nil,
                    sourceLine: line
                )

            case "TITLE":
                let value = tokens.count >= 2 ? tokens[1] : ""
                if current != nil {
                    current?.title = value
                } else {
                    sheetTitle = value
                }

            case "PERFORMER":
                let value = tokens.count >= 2 ? tokens[1] : ""
                if current != nil {
                    current?.performer = value
                } else {
                    sheetPerformer = value
                }

            case "INDEX":
                // INDEX NN MM:SS:FF (or MM:SS)
                guard tokens.count >= 3 else {
                    throw CueParseError.malformedIndex(line: line)
                }
                let indexNumber = Int(tokens[1])
                guard let seconds = parseTimestamp(tokens[2]) else {
                    throw CueParseError.malformedIndex(line: line)
                }
                if indexNumber == 1 {
                    if current?.index01 != nil, let num = current?.number {
                        throw CueParseError.duplicateIndex(trackNumber: num)
                    }
                    current?.index01 = seconds
                } else if indexNumber == 0 {
                    current?.index00 = seconds
                }

            default:
                // REM, CATALOG, ISRC, FLAGS, PREGAP, POSTGAP, CDTEXTFILE, etc. — ignored.
                continue
            }
        }

        if let last = current {
            rawTracks.append(last)
        }

        guard let path = fileDirectivePath else {
            throw CueParseError.noFileDirective
        }

        let audioFileURL = resolveAudioFileURL(path: path, sheetURL: sheetURL)
        guard FileManager.default.fileExists(atPath: audioFileURL.path) else {
            throw CueParseError.missingReferencedFile(audioFileURL)
        }

        let audioTracks = rawTracks.filter { $0.isAudio && $0.index01 != nil }
        guard !audioTracks.isEmpty else {
            throw CueParseError.noAudioTracks
        }

        // Reject sheets where two AUDIO tracks share the same INDEX 01 — the
        // resulting slice would have zero duration and auto-advance immediately,
        // which is a symptom of a malformed sheet rather than something to render.
        var seenStarts: [Double: Int] = [:]
        for raw in audioTracks {
            let start = raw.index01!
            if seenStarts[start] != nil {
                throw CueParseError.duplicateIndex(trackNumber: raw.number)
            }
            seenStarts[start] = raw.number
        }

        // Compute the underlying file duration so the last slice has a real length.
        let asset = AVURLAsset(url: audioFileURL)
        let fileDuration: Double
        do {
            let durationCM = try await asset.load(.duration)
            fileDuration = durationCM.seconds
        } catch {
            // Without the file duration we cannot bound the final slice; fall back to a
            // generous sentinel — the engine will EOF-cap at playback time.
            fileDuration = .greatestFiniteMagnitude
            AppLog.warn(.audio, "CUE: could not load duration for \(audioFileURL.lastPathComponent): \(error)")
        }

        // Build Track entries with computed slice durations.
        var tracks: [Track] = []
        for (i, raw) in audioTracks.enumerated() {
            let start = raw.index01!
            let nextStart: Double = (i + 1 < audioTracks.count)
                ? (audioTracks[i + 1].index01 ?? fileDuration)
                : fileDuration
            let duration = max(0, nextStart - start)

            let title = raw.title?.trimmingCharacters(in: .whitespaces).nonEmpty
                ?? sheetTitle?.trimmingCharacters(in: .whitespaces).nonEmpty
                ?? "Track \(raw.number)"
            let artist = raw.performer?.trimmingCharacters(in: .whitespaces).nonEmpty
                ?? sheetPerformer?.trimmingCharacters(in: .whitespaces).nonEmpty
                ?? "Unknown Artist"

            let slice = CueSlice(
                startTime: start,
                duration: duration,
                cueSheetURL: sheetURL
            )
            tracks.append(Track(
                url: audioFileURL,
                title: title,
                artist: artist,
                duration: duration,
                cueSlice: slice
            ))
        }

        return CueParseResult(audioFileURL: audioFileURL, sheetURL: sheetURL, tracks: tracks)
    }

    // MARK: - Sidecar Discovery

    /// File extensions for which MacAmp checks for a sidecar `.cue` when an audio
    /// file is added. Single-file lossless rips are the common case for sidecar CUE.
    static let sidecarEligibleExtensions: Set<String> = ["flac", "ape", "wv", "wav", "tta"]

    /// Return the sidecar `.cue` URL next to the given audio file if one exists, else nil.
    /// Matches `<basename>.cue` in the same directory (case-insensitive on the extension).
    static func sidecarCueURL(for audioFileURL: URL) -> URL? {
        let ext = audioFileURL.pathExtension.lowercased()
        guard sidecarEligibleExtensions.contains(ext) else { return nil }
        let candidate = audioFileURL.deletingPathExtension().appendingPathExtension("cue")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        // Some tools emit `name.flac.cue` (double extension); check that too.
        let doubleExt = audioFileURL.appendingPathExtension("cue")
        if FileManager.default.fileExists(atPath: doubleExt.path) {
            return doubleExt
        }
        return nil
    }

    // MARK: - Encoding Fallback

    /// Decode CUE bytes by trying UTF-16 (BOM), UTF-8, Shift-JIS, Windows-1252 in order.
    /// CP1252 always succeeds for arbitrary byte data, so it serves as the final fallback.
    private static func decode(data: Data) throws -> String {
        // UTF-16 BOM detection — common output from Windows CUE tools.
        // FF FE → UTF-16-LE; FE FF → UTF-16-BE. `.utf16` consumes the BOM.
        if data.count >= 2 {
            let b0 = data[0], b1 = data[1]
            if (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF) {
                if let s = String(data: data, encoding: .utf16) { return s }
            }
        }
        let stripped = stripUTF8BOM(data)
        if let s = String(data: stripped, encoding: .utf8) { return s }
        if let s = String(data: stripped, encoding: .shiftJIS) { return s }
        if let s = String(data: stripped, encoding: .windowsCP1252) { return s }
        throw CueParseError.encodingError
    }

    private static func stripUTF8BOM(_ data: Data) -> Data {
        // UTF-8 BOM: EF BB BF
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            return data.subdata(in: 3..<data.count)
        }
        return data
    }

    // MARK: - Tokenization

    /// Split a CUE line into directive + arguments. Honors double-quoted strings as a single token.
    private static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for c in line {
            switch c {
            case "\"":
                inQuotes.toggle()
            case " ", "\t":
                if inQuotes {
                    current.append(c)
                } else if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            default:
                current.append(c)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    /// Parse a CUE timestamp `MM:SS:FF` (CD frames are 1/75 s) or the lenient `MM:SS` form.
    /// Returns seconds as Double, or nil on parse failure.
    private static func parseTimestamp(_ s: String) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let minutes = Int(parts[0]), let seconds = Int(parts[1]) else { return nil }
        let frames: Int
        if parts.count == 3 {
            guard let f = Int(parts[2]) else { return nil }
            frames = f
        } else {
            frames = 0
        }
        return Double(minutes) * 60 + Double(seconds) + Double(frames) / 75.0
    }

    // MARK: - Path Resolution

    /// Resolve the FILE directive's path argument to an absolute URL.
    /// Mirrors M3UParser's resolution rules: HTTP/HTTPS, Unix absolute, Windows absolute, relative.
    private static func resolveAudioFileURL(path: String, sheetURL: URL) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return URL(string: trimmed) ?? sheetURL.deletingLastPathComponent().appendingPathComponent(trimmed)
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        // Windows absolute path (drive letter, e.g., "C:\Music\...")
        if trimmed.count > 2,
           trimmed[trimmed.index(trimmed.startIndex, offsetBy: 1)] == ":" {
            let unixPath = trimmed.replacingOccurrences(of: "\\", with: "/")
            return URL(fileURLWithPath: unixPath)
        }
        // Relative to the CUE file's directory.
        let baseDir = sheetURL.deletingLastPathComponent()
        let normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
        return URL(fileURLWithPath: normalized, relativeTo: baseDir).standardized
    }
}

// MARK: - Helpers

private extension String {
    /// Returns self if non-empty, nil otherwise — for `??` fall-through to defaults.
    var nonEmpty: String? { isEmpty ? nil : self }
}
