import Foundation

/// A parsed HLS playlist, reduced to the tags MacAmp acts on.
///
/// A media playlist lists the segments of one rendition. A master playlist
/// lists renditions (variants) of the same program.
enum HLSPlaylist: Equatable, Sendable {
    case media(Media)
    case master(Master)

    struct Segment: Equatable, Sendable {
        let url: URL
        let duration: Double
        /// Position in the stream: the playlist's media sequence plus the segment's index.
        let sequence: UInt64
        /// True when the segment follows an `#EXT-X-DISCONTINUITY` tag.
        let followsDiscontinuity: Bool
    }

    struct Media: Equatable, Sendable {
        let targetDuration: Double
        let mediaSequence: UInt64
        let segments: [Segment]
        /// True when the playlist carries `#EXT-X-ENDLIST`, so no segment will follow.
        let isEnded: Bool
    }

    struct Variant: Equatable, Sendable {
        let url: URL
        let bandwidth: Int
        let codecs: [String]
        let hasResolution: Bool

        /// A variant carries only audio when every declared codec is AAC, or when it
        /// declares no codecs and no video resolution.
        var isAudioOnly: Bool {
            if codecs.isEmpty { return !hasResolution }
            return codecs.allSatisfy { $0.hasPrefix("mp4a") }
        }
    }

    struct Master: Equatable, Sendable {
        let variants: [Variant]

        /// The audio-only variant with the lowest bandwidth.
        var lowestAudioOnlyVariant: Variant? {
            variants.filter(\.isAudioOnly).min { $0.bandwidth < $1.bandwidth }
        }
    }

    enum ParseError: Error, Equatable {
        case notHLS
        case missingTargetDuration
        case unsupportedEncryption
        case unsupportedInitSegment
        case unsupportedByteRange
        case invalidMediaSequence
    }

    /// Whether `content` is an HLS playlist rather than a plain M3U playlist.
    static func isHLS(_ content: String) -> Bool {
        guard content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
            return false
        }
        return content.contains("#EXT-X-TARGETDURATION") || content.contains("#EXT-X-STREAM-INF")
    }

    /// Parse `content`, resolving relative URIs against `base`.
    static func parse(_ content: String, relativeTo base: URL) throws -> HLSPlaylist {
        guard isHLS(content) else { throw ParseError.notHLS }

        var targetDuration: Double?
        var mediaSequence: UInt64 = 0
        var isEnded = false
        var segments: [Segment] = []
        var variants: [Variant] = []

        var pendingDuration: Double?
        var pendingDiscontinuity = false
        var pendingVariant: [String: String]?

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#") {
                if let value = value(of: "#EXT-X-TARGETDURATION", in: line) {
                    targetDuration = Double(value)
                } else if let value = value(of: "#EXT-X-MEDIA-SEQUENCE", in: line) {
                    guard let sequence = UInt64(value) else { throw ParseError.invalidMediaSequence }
                    mediaSequence = sequence
                } else if let value = value(of: "#EXTINF", in: line) {
                    pendingDuration = Double(value.split(separator: ",", maxSplits: 1).first ?? "")
                } else if line == "#EXT-X-DISCONTINUITY" {
                    pendingDiscontinuity = true
                } else if line == "#EXT-X-ENDLIST" {
                    isEnded = true
                } else if let value = value(of: "#EXT-X-KEY", in: line) {
                    if attributes(of: value)["METHOD"] != "NONE" {
                        throw ParseError.unsupportedEncryption
                    }
                } else if line.hasPrefix("#EXT-X-MAP") {
                    throw ParseError.unsupportedInitSegment
                } else if line.hasPrefix("#EXT-X-BYTERANGE") {
                    throw ParseError.unsupportedByteRange
                } else if let value = value(of: "#EXT-X-STREAM-INF", in: line) {
                    pendingVariant = attributes(of: value)
                }
                continue
            }

            guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { continue }

            if let attributes = pendingVariant {
                variants.append(Variant(
                    url: url,
                    bandwidth: Int(attributes["BANDWIDTH"] ?? "") ?? 0,
                    codecs: (attributes["CODECS"] ?? "").split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespaces)
                    },
                    hasResolution: attributes["RESOLUTION"] != nil
                ))
                pendingVariant = nil
            } else if let duration = pendingDuration {
                let (sequence, overflow) = mediaSequence.addingReportingOverflow(UInt64(segments.count))
                if overflow { throw ParseError.invalidMediaSequence }
                segments.append(Segment(
                    url: url,
                    duration: duration,
                    sequence: sequence,
                    followsDiscontinuity: pendingDiscontinuity
                ))
                pendingDuration = nil
                pendingDiscontinuity = false
            }
        }

        if !variants.isEmpty {
            return .master(Master(variants: variants))
        }
        guard let targetDuration else { throw ParseError.missingTargetDuration }
        return .media(Media(
            targetDuration: targetDuration,
            mediaSequence: mediaSequence,
            segments: segments,
            isEnded: isEnded
        ))
    }

    /// The text after `tag:` when `line` starts with that tag.
    private static func value(of tag: String, in line: String) -> String? {
        let prefix = tag + ":"
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    /// Split an attribute list such as `BANDWIDTH=1,CODECS="a,b"` into a dictionary.
    /// Commas inside quoted values do not separate attributes.
    private static func attributes(of list: String) -> [String: String] {
        var result: [String: String] = [:]
        var current = ""
        var inQuotes = false
        var parts: [String] = []
        for character in list {
            if character == "\"" {
                inQuotes.toggle()
            } else if character == "," && !inQuotes {
                parts.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        parts.append(current)

        for part in parts {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let key = part[..<equals].trimmingCharacters(in: .whitespaces)
            var value = part[part.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }
}
