import Foundation

/// Extracts the AAC audio of MPEG transport stream segments as an ADTS byte stream.
///
/// HLS segments hold ADTS frames inside PES packets. This type unwraps them and
/// leaves the frames alone: `AudioFileStream` finds frame boundaries itself, and
/// a frame may straddle PES packets.
///
/// The PAT and PMT are remembered across segments. A segment begins with audio
/// packets ahead of its own tables, so a demuxer that learned the tables per
/// segment would lose the first frame of each one.
///
/// Instances are not thread-safe: confine one to the queue that feeds it.
final class TransportStreamAudioDemuxer {
    enum Event: Equatable {
        /// ADTS bytes, in order.
        case audio(Data)
        /// Audio before this point is not contiguous with audio after it.
        case discontinuity
    }

    enum DemuxError: Error, Equatable {
        case unsupportedAudioCodec(streamType: UInt8)
    }

    private static let packetSize = 188
    private static let syncByte: UInt8 = 0x47
    private static let adtsAACStreamType: UInt8 = 0x0F
    /// MPEG audio, LATM AAC, AC-3 and E-AC-3 stream types: audio the demuxer does not carry.
    private static let otherAudioStreamTypes: Set<UInt8> = [0x03, 0x04, 0x11, 0x81, 0x87]

    // Kept across segments.
    private var pmtPID: Int?
    private var audioPID: Int?
    private var pendingDiscontinuity = false

    /// Report a discontinuity ahead of the next segment's audio. The tables are
    /// learned again, since a discontinuity may change the track identifiers.
    func markDiscontinuity() {
        pendingDiscontinuity = true
        pmtPID = nil
        audioPID = nil
    }

    /// Forget the tables and any pending discontinuity.
    func reset() {
        pmtPID = nil
        audioPID = nil
        pendingDiscontinuity = false
    }

    /// Demultiplex one whole segment. A PES packet still open at the end of the
    /// segment is completed there.
    func demux(segment: Data) throws -> [Event] {
        let bytes = [UInt8](segment)
        let run = Run()
        if pendingDiscontinuity {
            run.discontinuity()
            pendingDiscontinuity = false
        }

        // Segments start with audio ahead of their tables, so find the tables first.
        if audioPID == nil {
            let assemblers = Assemblers()
            try forEachPacket(in: bytes, onResync: { assemblers.reset() }) { offset in
                try self.readTables(packetAt: offset, in: bytes, assemblers: assemblers)
            }
        }

        let assemblers = Assemblers()
        try forEachPacket(in: bytes, onResync: {
            run.loseSync()
            assemblers.reset()
        }) { offset in
            let pid = Self.pid(of: bytes, at: offset)
            if pid == 0 || pid == self.pmtPID {
                try self.readTables(packetAt: offset, in: bytes, assemblers: assemblers)
            } else if pid == self.audioPID {
                run.audioPacket(at: offset, in: bytes)
            }
        }
        run.finish()
        return run.events
    }

    // MARK: - Packet framing

    /// Visit each 188-byte packet, resynchronizing after a lost sync byte.
    ///
    /// A segment is taken to start on a packet boundary. A packet is accepted when its
    /// sync byte is present and the next boundary also holds one, if a full next packet
    /// follows. When the next boundary is damaged, the packet is still accepted if it
    /// names a PID the demuxer follows and the stream resumes at least a whole packet
    /// later, which means bytes were inserted after it rather than before. A header
    /// inside the damage resumes sooner than that and is rejected. Acquiring sync
    /// elsewhere needs repeated sync bytes.
    /// `onResync` runs whenever bytes are known to be missing, including when no
    /// further sync can be found.
    private func forEachPacket(
        in bytes: [UInt8],
        onResync: () -> Void,
        _ body: (Int) throws -> Void
    ) rethrows {
        var offset: Int
        if bytes.first == Self.syncByte {
            offset = 0
        } else if let found = Self.findSync(in: bytes, from: 0) {
            offset = found
            onResync()
        } else {
            if !bytes.isEmpty { onResync() }
            return
        }
        while offset + Self.packetSize <= bytes.count {
            let next = offset + Self.packetSize
            let followedByPacket = next + Self.packetSize <= bytes.count
            var aligned = bytes[offset] == Self.syncByte
            if aligned && followedByPacket && bytes[next] != Self.syncByte {
                let resumes = Self.findSync(in: bytes, from: offset + 1)
                aligned = isFollowedPID(Self.pid(of: bytes, at: offset)) && (resumes.map { $0 >= next } ?? true)
            }
            if !aligned {
                onResync()
                guard let resumed = Self.findSync(in: bytes, from: offset + 1) else { return }
                offset = resumed
                continue
            }
            try body(offset)
            offset += Self.packetSize
        }
        // Bytes left over after the last whole packet are a truncated packet.
        if offset < bytes.count { onResync() }
    }

    private func isFollowedPID(_ pid: Int) -> Bool {
        pid == 0 || pid == pmtPID || pid == audioPID
    }

    /// The first offset at or after `start` where sync bytes repeat at successive
    /// packet intervals. A lone 0x47 inside a payload does not qualify, and neither
    /// does a header that merely names a PID. At least two packets must be in range,
    /// so a stray byte near the end cannot lock on.
    private static func findSync(in bytes: [UInt8], from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        for candidate in start..<bytes.count where bytes[candidate] == syncByte {
            let positions = (0..<3).map { candidate + $0 * packetSize }.filter { $0 < bytes.count }
            if positions.count >= 2 && positions.allSatisfy({ bytes[$0] == syncByte }) {
                return candidate
            }
        }
        return nil
    }

    private static func pid(of bytes: [UInt8], at offset: Int) -> Int {
        (Int(bytes[offset + 1] & 0x1F) << 8) | Int(bytes[offset + 2])
    }

    // MARK: - Tables

    private final class Assemblers {
        var pat = SectionAssembler()
        var pmt = SectionAssembler()

        func reset() {
            pat = SectionAssembler()
            pmt = SectionAssembler()
        }
    }

    private func readTables(packetAt offset: Int, in bytes: [UInt8], assemblers: Assemblers) throws {
        let pid = Self.pid(of: bytes, at: offset)
        guard pid == 0 || pid == pmtPID else { return }

        // Packets that fail the transport checks must not feed table parsing, and a
        // section in progress does not survive them. A discontinuity flag also ends the
        // section in progress, but the packet's own payload is still valid.
        let control = (bytes[offset + 3] >> 4) & 3
        let flagsDiscontinuity = control & 2 != 0 && bytes[offset + 4] > 0 && bytes[offset + 5] & 0x80 != 0
        let damaged = bytes[offset + 1] & 0x80 != 0 || (bytes[offset + 3] >> 6) & 3 != 0
        if damaged || flagsDiscontinuity {
            if pid == 0 { assemblers.pat = SectionAssembler() } else { assemblers.pmt = SectionAssembler() }
        }
        if damaged { return }
        guard let payload = Self.payload(ofPacketAt: offset, in: bytes) else { return }
        let startsUnit = bytes[offset + 1] & 0x40 != 0
        let counter = bytes[offset + 3] & 0x0F

        if pid == 0 {
            for section in assemblers.pat.add(payload, startsUnit: startsUnit, counter: counter) {
                readPAT(section)
            }
        } else {
            for section in assemblers.pmt.add(payload, startsUnit: startsUnit, counter: counter) {
                try readPMT(section)
            }
        }
    }

    /// The payload bytes of a packet, or nil when it has none or its adaptation
    /// field overruns the packet.
    private static func payload(ofPacketAt offset: Int, in bytes: [UInt8]) -> ArraySlice<UInt8>? {
        let control = (bytes[offset + 3] >> 4) & 3
        guard control & 1 != 0 else { return nil }
        var start = offset + 4
        if control & 2 != 0 {
            start = offset + 5 + Int(bytes[offset + 4])
        }
        guard start <= offset + packetSize else { return nil }
        return bytes[start..<(offset + packetSize)]
    }

    private func readPAT(_ section: [UInt8]) {
        guard section[0] == 0x00, section.count >= 12, section[5] & 1 == 1 else { return }
        var index = 8
        while index + 4 <= section.count - 4 {
            let program = (Int(section[index]) << 8) | Int(section[index + 1])
            let pid = (Int(section[index + 2] & 0x1F) << 8) | Int(section[index + 3])
            if program != 0 {
                if pmtPID != pid {
                    pmtPID = pid
                    audioPID = nil
                }
                return
            }
            index += 4
        }
    }

    private func readPMT(_ section: [UInt8]) throws {
        guard section[0] == 0x02, section.count >= 16, section[5] & 1 == 1 else { return }
        let programInfoLength = (Int(section[10] & 0x0F) << 8) | Int(section[11])
        var index = 12 + programInfoLength
        let end = section.count - 4
        var unsupported: UInt8?
        var audio: Int?
        while index + 5 <= end {
            let streamType = section[index]
            let pid = (Int(section[index + 1] & 0x1F) << 8) | Int(section[index + 2])
            let infoLength = (Int(section[index + 3] & 0x0F) << 8) | Int(section[index + 4])
            if streamType == Self.adtsAACStreamType, audio == nil {
                audio = pid
            } else if Self.otherAudioStreamTypes.contains(streamType), unsupported == nil {
                unsupported = streamType
            }
            index += 5 + infoLength
        }
        if let audio {
            audioPID = audio
        } else if let unsupported {
            throw DemuxError.unsupportedAudioCodec(streamType: unsupported)
        }
    }

    /// Reassembles PSI sections that may span packets or share one.
    private struct SectionAssembler {
        private var buffer: [UInt8] = []
        private var active = false
        private var lastCounter: UInt8?
        private var lastPayload: ArraySlice<UInt8> = []

        mutating func add(_ payload: ArraySlice<UInt8>, startsUnit: Bool, counter: UInt8) -> [[UInt8]] {
            // A repeated packet adds nothing; a skipped counter loses the section in progress.
            if let last = lastCounter {
                if counter == last && payload.elementsEqual(lastPayload) { return [] }
                if counter != (last &+ 1) & 0x0F {
                    buffer = []
                    active = false
                }
            }
            lastCounter = counter
            lastPayload = payload

            var sections: [[UInt8]] = []
            if startsUnit {
                guard let pointer = payload.first.map(Int.init) else { return [] }
                let tailEnd = payload.startIndex + 1 + pointer
                guard tailEnd <= payload.endIndex else { active = false; return [] }
                if active {
                    buffer.append(contentsOf: payload[(payload.startIndex + 1)..<tailEnd])
                    drain(into: &sections)
                }
                buffer = Array(payload[tailEnd...])
                active = true
            } else if active {
                buffer.append(contentsOf: payload)
            }
            drain(into: &sections)
            return sections
        }

        private mutating func drain(into sections: inout [[UInt8]]) {
            while buffer.count >= 3 {
                if buffer[0] == 0xFF {
                    buffer = []
                    return
                }
                let total = 3 + ((Int(buffer[1] & 0x0F) << 8) | Int(buffer[2]))
                guard buffer.count >= total else { return }
                sections.append(Array(buffer[0..<total]))
                buffer.removeFirst(total)
            }
        }
    }

    // MARK: - Audio

    /// State of one `demux(segment:)` call.
    private final class Run {
        private(set) var events: [Event] = []
        private var audio = Data()

        private var pes: [UInt8] = []
        private var pesOpen = false
        private var lastCounter: UInt8?
        private var lastPayload: ArraySlice<UInt8> = []

        func discontinuity() {
            flushAudio()
            events.append(.discontinuity)
        }

        /// Bytes are missing. The open PES packet is kept only if its declared length
        /// is already in hand, since otherwise it is truncated.
        func loseSync() {
            closeAfterLoss()
            lastCounter = nil
            discontinuity()
        }

        func finish() {
            completePES()
            flushAudio()
        }

        func audioPacket(at offset: Int, in bytes: [UInt8]) {
            let transportError = bytes[offset + 1] & 0x80 != 0
            let startsUnit = bytes[offset + 1] & 0x40 != 0
            let scrambled = (bytes[offset + 3] >> 6) & 3 != 0
            let control = (bytes[offset + 3] >> 4) & 3
            let counter = bytes[offset + 3] & 0x0F

            if transportError || scrambled {
                loseSync()
                return
            }

            var payloadStart = offset + 4
            var flagsDiscontinuity = false
            if control & 2 != 0 {
                let length = Int(bytes[offset + 4])
                if length > 0 { flagsDiscontinuity = bytes[offset + 5] & 0x80 != 0 }
                payloadStart = offset + 5 + length
                guard payloadStart <= offset + TransportStreamAudioDemuxer.packetSize else {
                    loseSync()
                    return
                }
            }
            if flagsDiscontinuity { loseSync() }

            // A packet without payload leaves the counter where it was.
            guard control & 1 != 0 else { return }
            let payload = bytes[payloadStart..<(offset + TransportStreamAudioDemuxer.packetSize)]

            if let last = lastCounter {
                if counter == last && payload.elementsEqual(lastPayload) { return }
                if counter != (last &+ 1) & 0x0F {
                    closeAfterLoss()
                    discontinuity()
                }
            }
            lastCounter = counter
            lastPayload = payload

            if startsUnit {
                completePES()
                pes = Array(payload)
                pesOpen = true
            } else if pesOpen {
                pes.append(contentsOf: payload)
            }
        }

        private func dropPES() {
            pes = []
            pesOpen = false
        }

        private func closeAfterLoss() {
            let declared = pes.count >= 6 ? (Int(pes[4]) << 8) | Int(pes[5]) : 0
            if pesOpen, declared != 0, pes.count >= 6 + declared {
                completePES()
            } else {
                dropPES()
            }
        }

        /// Move the open PES packet's payload into the audio, or report a discontinuity
        /// when the packet is malformed or truncated.
        private func completePES() {
            guard pesOpen else { return }
            defer { dropPES() }

            guard pes.count >= 9, pes[0] == 0, pes[1] == 0, pes[2] == 1 else {
                discontinuity()
                return
            }
            let declared = (Int(pes[4]) << 8) | Int(pes[5])
            let payloadStart = 9 + Int(pes[8])
            let end = declared == 0 ? pes.count : 6 + declared
            guard payloadStart <= end, end <= pes.count else {
                discontinuity()
                return
            }
            audio.append(contentsOf: pes[payloadStart..<end])
        }

        private func flushAudio() {
            guard !audio.isEmpty else { return }
            events.append(.audio(audio))
            audio = Data()
        }
    }
}
