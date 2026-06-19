import Foundation
import AVFoundation
import AudioToolbox

/// Full read-only metadata and format facts for one media file, gathered for
/// the File Info dialog. Every field is optional; a `nil` means the value was
/// absent in the file (or does not apply to the codec) and the dialog renders
/// the field's label with an empty value rather than substituting a guess.
struct FileInfo: Sendable {
    // Metadata
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNumber: String?
    var discNumber: String?
    var year: String?
    var genre: String?
    var bpm: String?
    var composer: String?
    var publisher: String?
    var comment: String?

    // Format
    var formatName: String?
    var payloadSizeBytes: UInt64?
    var headerOffsetBytes: Int64?
    var lengthSeconds: Double?
    var bitrateKbps: Int?
    var frameCount: UInt64?
    var sampleRateHz: Int?
    var channelCount: Int?
    /// MPEG channel mode (Stereo / Joint Stereo / Dual Channel / Mono); `nil`
    /// for non-MPEG audio, where only `channelCount` applies.
    var channelMode: String?

    // MPEG frame-header fields; `nil` for non-MPEG audio.
    var isMPEG: Bool = false
    var crc: Bool?
    var copyrighted: Bool?
    var original: Bool?
    var emphasis: String?

    // Replay gain (formatted as "%+.2f dB"); `nil` when the frame is absent.
    var trackGain: String?
    var albumGain: String?
}

extension MetadataLoader {

    /// Gather the full File Info field set for `url` from AVFoundation metadata,
    /// Core Audio `AudioFile` properties, and — for MPEG audio — the first frame
    /// header. Returns whatever could be read; missing values stay `nil`.
    static func loadFileInfo(from url: URL) async -> FileInfo {
        var info = FileInfo()

        // Core Audio: byte/packet/offset/bitrate/format facts.
        let ca = readCoreAudioInfo(url)
        if let ca {
            info.payloadSizeBytes = ca.payloadBytes
            info.frameCount = ca.packetCount
            info.headerOffsetBytes = ca.dataOffset
            info.sampleRateHz = ca.sampleRate > 0 ? Int(ca.sampleRate.rounded()) : nil
            info.channelCount = ca.channels > 0 ? Int(ca.channels) : nil
            info.bitrateKbps = ca.bitrateBps > 0 ? Int((Double(ca.bitrateBps) / 1000).rounded()) : nil
            info.isMPEG = ca.isMPEG

            if ca.isMPEG, let header = readMPEGFrameHeader(url, dataOffset: ca.dataOffset) {
                info.formatName = "MPEG-\(header.version) layer \(header.layerNumber)"
                info.channelMode = header.channelMode
                info.crc = header.crc
                info.copyrighted = header.copyrighted
                info.original = header.original
                info.emphasis = header.emphasis
            } else {
                info.formatName = formatName(for: ca.formatID)
            }
        }

        // AVFoundation: tags + duration.
        let asset = AVURLAsset(url: url)
        if let durationCM = try? await asset.load(.duration) {
            let s = durationCM.seconds
            if s.isFinite, s > 0 { info.lengthSeconds = s }
        }

        let common = (try? await asset.load(.commonMetadata)) ?? []
        var tagged: [AVMetadataItem] = []
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for f in formats { tagged += (try? await asset.loadMetadata(for: f)) ?? [] }
        }
        let all = common + tagged

        func string(of item: AVMetadataItem) async -> String? {
            guard let s = try? await item.load(.stringValue) else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func byCommon(_ key: AVMetadataKey) async -> String? {
            for item in all where item.commonKey == key {
                if let v = await string(of: item) { return v }
            }
            return nil
        }
        func byFrame(_ frame: String) async -> String? {
            for item in tagged where item.identifier?.rawValue.hasSuffix("/\(frame)") ?? false {
                if let v = await string(of: item) { return v }
            }
            return nil
        }

        func firstOf(_ producers: () async -> String?...) async -> String? {
            for produce in producers {
                if let v = await produce() { return v }
            }
            return nil
        }

        info.title = await firstOf({ await byCommon(.commonKeyTitle) }, { await byFrame("TIT2") })
        info.artist = await firstOf({ await byCommon(.commonKeyArtist) }, { await byFrame("TPE1") })
        info.album = await firstOf({ await byCommon(.commonKeyAlbumName) }, { await byFrame("TALB") })
        info.albumArtist = await byFrame("TPE2")
        info.trackNumber = await byFrame("TRCK")
        info.discNumber = await byFrame("TPOS")
        info.genre = await firstOf({ await byFrame("TCON") }, { await byCommon(.commonKeyType) })
        if let rawBPM = await byFrame("TBPM") {
            // TBPM is a number; some tags append the unit ("130 BPM"). Keep the
            // number only — the field already sits under a "BPM" label.
            let number = rawBPM.prefix { $0.isNumber || $0 == "." }
            info.bpm = number.isEmpty ? nil : String(number)
        }
        info.composer = await byFrame("TCOM")
        info.publisher = await byFrame("TPUB")
        info.comment = await byFrame("COMM")

        if let raw = await firstOf({ await byFrame("TDRC") }, { await byFrame("TYER") }, { await byCommon(.commonKeyCreationDate) }) {
            info.year = year(from: raw)
        }

        if let raw = await replayGain("replaygain_track_gain", in: tagged) { info.trackGain = raw }
        if let raw = await replayGain("replaygain_album_gain", in: tagged) { info.albumGain = raw }

        return info
    }

    // MARK: - Core Audio

    private struct CoreAudioInfo {
        var formatID: AudioFormatID
        var sampleRate: Double
        var channels: UInt32
        var payloadBytes: UInt64
        var packetCount: UInt64
        var bitrateBps: UInt32
        var dataOffset: Int64
        var isMPEG: Bool
    }

    private static func readCoreAudioInfo(_ url: URL) -> CoreAudioInfo? {
        var afid: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &afid) == noErr,
              let af = afid else { return nil }
        defer { AudioFileClose(af) }

        func u64(_ prop: AudioFilePropertyID) -> UInt64 {
            var v: UInt64 = 0
            var sz = UInt32(MemoryLayout<UInt64>.size)
            return AudioFileGetProperty(af, prop, &sz, &v) == noErr ? v : 0
        }
        func u32(_ prop: AudioFilePropertyID) -> UInt32 {
            var v: UInt32 = 0
            var sz = UInt32(MemoryLayout<UInt32>.size)
            return AudioFileGetProperty(af, prop, &sz, &v) == noErr ? v : 0
        }

        var asbd = AudioStreamBasicDescription()
        var asz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(af, kAudioFilePropertyDataFormat, &asz, &asbd) == noErr else { return nil }

        var offset: Int64 = 0
        var osz = UInt32(MemoryLayout<Int64>.size)
        _ = AudioFileGetProperty(af, kAudioFilePropertyDataOffset, &osz, &offset)

        let isMPEG = asbd.mFormatID == kAudioFormatMPEGLayer1
            || asbd.mFormatID == kAudioFormatMPEGLayer2
            || asbd.mFormatID == kAudioFormatMPEGLayer3

        return CoreAudioInfo(
            formatID: asbd.mFormatID,
            sampleRate: asbd.mSampleRate,
            channels: asbd.mChannelsPerFrame,
            payloadBytes: u64(kAudioFilePropertyAudioDataByteCount),
            packetCount: u64(kAudioFilePropertyAudioDataPacketCount),
            bitrateBps: u32(kAudioFilePropertyBitRate),
            dataOffset: offset,
            isMPEG: isMPEG
        )
    }

    // MARK: - MPEG frame header

    private struct MPEGHeader {
        var version: String      // "1", "2", "2.5"
        var layerNumber: Int     // 1, 2, 3
        var channelMode: String
        var crc: Bool
        var copyrighted: Bool
        var original: Bool
        var emphasis: String
    }

    /// Read and decode the 4-byte MPEG audio frame header at `dataOffset`.
    /// Returns `nil` if the sync word is absent (e.g. the offset does not point
    /// at a real frame). Strings match Winamp's `MP3Info.cpp` exactly.
    private static func readMPEGFrameHeader(_ url: URL, dataOffset: Int64) -> MPEGHeader? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(max(0, dataOffset)))
        guard let d = try? fh.read(upToCount: 4), d.count == 4 else { return nil }

        let h = (UInt32(d[0]) << 24) | (UInt32(d[1]) << 16) | (UInt32(d[2]) << 8) | UInt32(d[3])
        guard (h >> 21) & 0x7FF == 0x7FF else { return nil }

        let version = ["2.5", "", "2", "1"][Int((h >> 19) & 0x3)]
        let layerNumber = [0, 3, 2, 1][Int((h >> 17) & 0x3)]
        guard !version.isEmpty, layerNumber != 0 else { return nil }

        let mode = ["Stereo", "Joint Stereo", "2 Channel", "Mono"][Int((h >> 6) & 0x3)]
        let emphasis = ["None", "50/15 microsec", "invalid", "CITT j.17"][Int(h & 0x3)]

        return MPEGHeader(
            version: version,
            layerNumber: layerNumber,
            channelMode: mode,
            crc: ((h >> 16) & 0x1) == 0,
            copyrighted: ((h >> 3) & 0x1) == 1,
            original: ((h >> 2) & 0x1) == 1,
            emphasis: emphasis
        )
    }

    // MARK: - Helpers

    private static func formatName(for id: AudioFormatID) -> String {
        switch id {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: return "AAC"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatAppleLossless: return "Apple Lossless"
        case kAudioFormatLinearPCM: return "PCM"
        case kAudioFormatOpus: return "Opus"
        default:
            let b = [UInt8((id >> 24) & 0xFF), UInt8((id >> 16) & 0xFF), UInt8((id >> 8) & 0xFF), UInt8(id & 0xFF)]
            let s = String(bytes: b.filter { $0 >= 32 && $0 < 127 }, encoding: .ascii) ?? ""
            return s.trimmingCharacters(in: .whitespaces).uppercased()
        }
    }

    /// Extract a 4-digit year from an ID3 year/date string such as `2004`,
    /// `2004-05-15`, or `2004-05-15T00:00:00Z`.
    private static func year(from raw: String) -> String? {
        let digits = raw.prefix { $0.isNumber }
        return digits.count >= 4 ? String(digits.prefix(4)) : (digits.isEmpty ? nil : String(digits))
    }

    /// Find an ID3 `TXXX` user-text frame by description and format its numeric
    /// value as `%+.2f dB`. Returns `nil` when no matching frame is present.
    private static func replayGain(_ description: String, in items: [AVMetadataItem]) async -> String? {
        for item in items where item.identifier?.rawValue.hasSuffix("/TXXX") ?? false {
            let info = item.extraAttributes?[.info] as? String
            guard info?.lowercased() == description else { continue }
            guard let raw = try? await item.load(.stringValue) else { continue }
            let token = raw.replacingOccurrences(of: "dB", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let value = Double(token) {
                return String(format: "%+.2f dB", value)
            }
        }
        return nil
    }
}
