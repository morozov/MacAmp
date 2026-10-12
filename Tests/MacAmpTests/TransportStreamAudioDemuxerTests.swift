import Foundation
import Testing
@testable import MacAmp

@Suite("Transport stream audio demuxer", .tags(.audio, .parsing))
struct TransportStreamAudioDemuxerTests {
    private final class BundleToken {}

    private typealias Event = TransportStreamAudioDemuxer.Event

    private let audioPID = 0x100
    private let metadataPID = 0x101
    private let pmtPID = 0x1000

    // MARK: - Packet builders

    /// A 188-byte packet. A short payload is padded with adaptation-field stuffing.
    private func packet(
        pid: Int,
        counter: Int,
        payload: [UInt8],
        startsUnit: Bool = false,
        transportError: Bool = false,
        scrambling: UInt8 = 0,
        discontinuityIndicator: Bool = false,
        withPayload: Bool = true
    ) -> [UInt8] {
        precondition(payload.count <= 184)
        var bytes: [UInt8] = [0x47]
        bytes.append((transportError ? 0x80 : 0) | (startsUnit ? 0x40 : 0) | UInt8(pid >> 8))
        bytes.append(UInt8(pid & 0xFF))

        let body = withPayload ? payload : []
        let stuffing = 184 - body.count
        let hasAdaptation = stuffing > 0 || discontinuityIndicator
        let control: UInt8 = (hasAdaptation ? 2 : 0) | (withPayload ? 1 : 0)
        bytes.append((scrambling << 6) | (control << 4) | UInt8(counter & 0x0F))
        if hasAdaptation {
            let length = stuffing - 1
            bytes.append(UInt8(length))
            if length > 0 {
                bytes.append(discontinuityIndicator ? 0x80 : 0x00)
                bytes.append(contentsOf: [UInt8](repeating: 0xFF, count: length - 1))
            }
        }
        bytes.append(contentsOf: body)
        precondition(bytes.count == 188, "built \(bytes.count) bytes")
        return bytes
    }

    private func section(tableID: UInt8, body: [UInt8]) -> [UInt8] {
        // table_id, section_length, then body, then a CRC the demuxer does not check.
        let length = body.count + 4
        return [tableID, 0xB0 | UInt8(length >> 8), UInt8(length & 0xFF)] + body + [0, 0, 0, 0]
    }

    private func patSection() -> [UInt8] {
        section(tableID: 0x00, body: [0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xE0 | UInt8(pmtPID >> 8), UInt8(pmtPID & 0xFF)])
    }

    private func pmtSection(streams: [(type: UInt8, pid: Int)], programInfo: [UInt8] = []) -> [UInt8] {
        var body: [UInt8] = [0x00, 0x01, 0xC1, 0x00, 0x00, 0xE1, 0x00, 0xF0 | UInt8(programInfo.count >> 8), UInt8(programInfo.count & 0xFF)]
        body.append(contentsOf: programInfo)
        for stream in streams {
            body.append(contentsOf: [stream.type, 0xE0 | UInt8(stream.pid >> 8), UInt8(stream.pid & 0xFF), 0xF0, 0x00])
        }
        return section(tableID: 0x02, body: body)
    }

    private func tables(audioType: UInt8 = 0x0F, audio: Int? = nil) -> [UInt8] {
        packet(pid: 0, counter: 0, payload: [0x00] + patSection(), startsUnit: true)
            + packet(pid: pmtPID, counter: 0, payload: [0x00] + pmtSection(streams: [(audioType, audio ?? audioPID), (0x15, metadataPID)]), startsUnit: true)
    }

    /// A PES packet carrying `payload`, as the packets that hold it.
    private func pes(_ payload: [UInt8], counter: inout Int, declaredLength: Bool = false, headerSplit: Int? = nil, pid: Int? = nil) -> [UInt8] {
        let header: [UInt8] = [0, 0, 1, 0xC0, 0, 0, 0x80, 0x80, 5, 0x21, 0, 1, 0, 1]
        var bytes = header + payload
        if declaredLength {
            let length = bytes.count - 6
            bytes[4] = UInt8(length >> 8)
            bytes[5] = UInt8(length & 0xFF)
        }
        return packets(carrying: bytes, counter: &counter, firstChunk: headerSplit, pid: pid ?? audioPID)
    }

    private func packets(carrying bytes: [UInt8], counter: inout Int, firstChunk: Int? = nil, pid: Int) -> [UInt8] {
        var out: [UInt8] = []
        var rest = bytes[...]
        var first = true
        while !rest.isEmpty {
            let size = first ? min(firstChunk ?? 184, rest.count) : min(184, rest.count)
            out += packet(pid: pid, counter: counter, payload: Array(rest.prefix(size)), startsUnit: first)
            counter += 1
            rest = rest.dropFirst(size)
            first = false
        }
        return out
    }

    private func adts(_ marker: UInt8) -> [UInt8] {
        [0xFF, 0xF1, 0x50, 0x80, 0x02, 0x1F, 0xFC, marker, marker]
    }

    private func audioBytes(of events: [Event]) -> [UInt8] {
        events.reduce(into: []) { result, event in
            if case .audio(let data) = event { result += data }
        }
    }

    // MARK: - Real segment

    @Test("A real segment yields every ADTS frame, including those ahead of its tables")
    func realSegment() throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "hls-segment", withExtension: "ts"))
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(contentsOf: url))

        #expect(events.count == 1)
        guard case .audio(let data)? = events.first else {
            Issue.record("expected one audio event")
            return
        }
        #expect(data.count == 11498)
        #expect(Array(data.prefix(7)) == [0xFF, 0xF1, 0x50, 0x80, 0x23, 0xBF, 0xFC])

        var frames = 0
        var position = 0
        let bytes = [UInt8](data)
        while position + 7 <= bytes.count {
            #expect(bytes[position] == 0xFF && bytes[position + 1] & 0xF0 == 0xF0)
            position += (Int(bytes[position + 3] & 3) << 11) | (Int(bytes[position + 4]) << 3) | Int(bytes[position + 5] >> 5)
            frames += 1
        }
        #expect(frames == 40)
        #expect(position == bytes.count)
    }

    // MARK: - Tables

    @Test("The tables are remembered, so a later segment without them still yields audio")
    func tablesPersistAcrossSegments() throws {
        let demuxer = TransportStreamAudioDemuxer()
        var counter = 0
        _ = try demuxer.demux(segment: Data(tables() + pes(adts(1), counter: &counter)))

        counter = 0
        let events = try demuxer.demux(segment: Data(pes(adts(2), counter: &counter) + pes(adts(3), counter: &counter)))
        #expect(audioBytes(of: events) == adts(2) + adts(3))
    }

    @Test("Audio packets ahead of the tables in a segment are kept")
    func audioAheadOfTables() throws {
        var counter = 0
        let segment = pes(adts(1), counter: &counter) + tables() + pes(adts(2), counter: &counter)
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(segment))
        #expect(audioBytes(of: events) == adts(1) + adts(2))
        #expect(!events.contains(.discontinuity))
    }

    @Test("A PMT that spans two packets is read once complete")
    func pmtSpansPackets() throws {
        let pat = packet(pid: 0, counter: 0, payload: [0x00] + patSection(), startsUnit: true)
        let long = pmtSection(streams: [(0x0F, audioPID)], programInfo: [UInt8](repeating: 0x05, count: 200))
        let first = packet(pid: pmtPID, counter: 0, payload: [0x00] + Array(long.prefix(183)), startsUnit: true)
        let second = packet(pid: pmtPID, counter: 1, payload: Array(long.dropFirst(183)))
        var counter = 0
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(pat + first + second + pes(adts(1), counter: &counter)))
        #expect(audioBytes(of: events) == adts(1))
    }

    @Test("A stream of an audio type the demuxer does not carry is rejected")
    func unsupportedCodec() {
        var counter = 0
        let segment = tables(audioType: 0x03) + pes(adts(1), counter: &counter)
        #expect(throws: TransportStreamAudioDemuxer.DemuxError.unsupportedAudioCodec(streamType: 0x03)) {
            try TransportStreamAudioDemuxer().demux(segment: Data(segment))
        }
    }

    @Test("Packets on other PIDs are ignored")
    func otherPIDsIgnored() throws {
        var counter = 0
        let id3 = packet(pid: metadataPID, counter: 0, payload: [0, 0, 1, 0xBD, 0, 0, 0x80, 0, 0, 0x49, 0x44, 0x33], startsUnit: true)
        let segment = tables() + id3 + pes(adts(1), counter: &counter)
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(segment))
        #expect(events == [.audio(Data(adts(1)))])
    }

    // MARK: - PES

    @Test("A PES header split across two packets is assembled")
    func pesHeaderSpansPackets() throws {
        var counter = 0
        let segment = tables() + pes(adts(1), counter: &counter, headerSplit: 5)
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(segment))
        #expect(audioBytes(of: events) == adts(1))
    }

    @Test("A declared PES length trims trailing bytes")
    func declaredLengthTrims() throws {
        let declared = 8 + adts(1).count
        let header: [UInt8] = [0, 0, 1, 0xC0, UInt8(declared >> 8), UInt8(declared & 0xFF), 0x80, 0x80, 5, 0x21, 0, 1, 0, 1]
        let padded = packet(pid: audioPID, counter: 0, payload: header + adts(1) + [0xEE, 0xEE, 0xEE], startsUnit: true)
        var counter = 1
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(tables() + padded + pes(adts(2), counter: &counter)))
        #expect(audioBytes(of: events) == adts(1) + adts(2))
    }

    @Test("A PES packet that does not start with the start code is dropped with a discontinuity")
    func malformedPES() throws {
        let bad = packet(pid: audioPID, counter: 0, payload: [9, 9, 9, 9, 9, 9, 9, 9, 9, 9], startsUnit: true)
        var counter = 1
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(tables() + bad + pes(adts(2), counter: &counter)))
        #expect(events == [.discontinuity, .audio(Data(adts(2)))])
    }

    @Test("Payload continuing a PES that never started is dropped")
    func continuationWithoutStart() throws {
        let orphan = packet(pid: audioPID, counter: 0, payload: adts(9))
        var counter = 1
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(tables() + orphan + pes(adts(1), counter: &counter)))
        #expect(audioBytes(of: events) == adts(1))
    }

    // MARK: - Continuity

    @Test("A continuity gap keeps a PES whose declared length is complete and reports the discontinuity in order")
    func continuityGap() throws {
        var counter = 0
        let first = pes(adts(1), counter: &counter, declaredLength: true)
        counter += 2
        let second = pes(adts(2), counter: &counter)
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(tables() + first + second))
        #expect(events == [.audio(Data(adts(1))), .discontinuity, .audio(Data(adts(2)))])
    }

    @Test("A continuity gap drops an open PES that cannot be shown to be complete")
    func continuityGapDropsTruncatedPES() throws {
        var counter = 0
        let first = pes(adts(1), counter: &counter)
        counter += 2
        let second = pes(adts(2), counter: &counter)
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(tables() + first + second))
        #expect(events == [.discontinuity, .audio(Data(adts(2)))])
    }

    @Test("A duplicate packet adds no bytes")
    func duplicatePacket() throws {
        var counter = 0
        let once = pes(adts(1), counter: &counter)
        let twice = once + once.suffix(188)
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(tables() + twice))
        #expect(audioBytes(of: events) == adts(1))
        #expect(!events.contains(.discontinuity))
    }

    @Test("A packet without payload does not advance the counter")
    func adaptationOnlyPacket() throws {
        let first = packet(pid: audioPID, counter: 0, payload: [0, 0, 1, 0xC0, 0, 0, 0x80, 0, 0] + adts(1), startsUnit: true)
        let filler = packet(pid: audioPID, counter: 0, payload: [], withPayload: false)
        var counter = 1
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(tables() + first + filler + pes(adts(2), counter: &counter)))
        #expect(audioBytes(of: events) == adts(1) + adts(2))
        #expect(!events.contains(.discontinuity))
    }

    @Test("The adaptation field's discontinuity indicator is reported")
    func adaptationDiscontinuityIndicator() throws {
        var counter = 0
        let first = pes(adts(1), counter: &counter, declaredLength: true)
        let flagged = packet(pid: audioPID, counter: counter, payload: [0, 0, 1, 0xC0, 0, 0, 0x80, 0, 0] + adts(2), startsUnit: true, discontinuityIndicator: true)
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(tables() + first + flagged))
        #expect(events == [.audio(Data(adts(1))), .discontinuity, .audio(Data(adts(2)))])
    }

    @Test("Transport-error and scrambled packets are dropped with a discontinuity")
    func errorAndScrambledPackets() throws {
        var counter = 0
        let first = pes(adts(1), counter: &counter, declaredLength: true)
        let broken = packet(pid: audioPID, counter: counter, payload: adts(9), transportError: true)
        counter += 1
        let scrambled = packet(pid: audioPID, counter: counter, payload: adts(9), scrambling: 2)
        counter += 1
        let last = pes(adts(2), counter: &counter)
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(tables() + first + broken + scrambled + last))
        #expect(audioBytes(of: events) == adts(1) + adts(2))
        #expect(events.filter { $0 == .discontinuity }.count == 2)
    }

    @Test("A marked discontinuity precedes the next segment's audio")
    func markedDiscontinuity() throws {
        let demuxer = TransportStreamAudioDemuxer()
        demuxer.markDiscontinuity()
        var counter = 0
        let events = try demuxer.demux(segment: Data(tables() + pes(adts(1), counter: &counter)))
        #expect(events == [.discontinuity, .audio(Data(adts(1)))])

        counter = 0
        let next = try demuxer.demux(segment: Data(pes(adts(2), counter: &counter) + pes(adts(3), counter: &counter)))
        #expect(next == [.audio(Data(adts(2) + adts(3)))])
    }

    // MARK: - Synchronization

    @Test("Garbage ahead of the first packet is skipped and reported")
    func garbageAhead() throws {
        var counter = 0
        let garbage: [UInt8] = [0x01, 0x02, 0x47, 0x03, 0x04, 0x05]
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(garbage + tables() + pes(adts(1), counter: &counter)))
        #expect(events == [.discontinuity, .audio(Data(adts(1)))])
    }

    @Test("Sync is regained after lost bytes, and a lone 0x47 in the garbage does not mislead it")
    func resyncMidSegment() throws {
        var counter = 0
        let first = pes(adts(1), counter: &counter, declaredLength: true)
        let garbage: [UInt8] = [0x47, 0x10, 0x47, 0x11, 0x12]
        counter += 3
        let rest = pes(adts(2), counter: &counter) + pes(adts(3), counter: &counter) + pes(adts(4), counter: &counter)
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(tables() + first + garbage + rest))
        #expect(events == [.audio(Data(adts(1))), .discontinuity, .audio(Data(adts(2) + adts(3) + adts(4)))])
    }

    @Test("A good packet is kept when damage begins right after it")
    func goodPacketBeforeDamage() throws {
        var counter = 0
        let first = pes(adts(1), counter: &counter, declaredLength: true)
        let garbage: [UInt8] = [0x10, 0x11, 0x12]
        counter += 3
        let rest = pes(adts(2), counter: &counter) + pes(adts(3), counter: &counter) + pes(adts(4), counter: &counter)
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(tables() + first + garbage + rest))
        #expect(events == [.audio(Data(adts(1))), .discontinuity, .audio(Data(adts(2) + adts(3) + adts(4)))])
    }

    @Test("Sync that cannot be regained still reports the loss and drops a PES of unknown length")
    func unrecoverableLoss() throws {
        var counter = 0
        let open = pes(adts(1), counter: &counter)
        let garbage = [UInt8](repeating: 0x55, count: 60)
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(tables() + open + garbage))
        #expect(events == [.discontinuity])
    }

    @Test("A truncated final packet is reported after the audio already complete")
    func truncatedTail() throws {
        var counter = 0
        let complete = pes(adts(1), counter: &counter, declaredLength: true)
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(tables() + complete + [UInt8](repeating: 0x47, count: 40)))
        #expect(events == [.audio(Data(adts(1))), .discontinuity])
    }

    @Test("A damaged PMT packet cannot change routing or fail the segment")
    func damagedPMT() throws {
        var counter = 0
        let pat = packet(pid: 0, counter: 0, payload: [0x00] + patSection(), startsUnit: true)
        let bad = packet(pid: pmtPID, counter: 0, payload: [0x00] + pmtSection(streams: [(0x03, audioPID)]), startsUnit: true, transportError: true)
        let good = packet(pid: pmtPID, counter: 1, payload: [0x00] + pmtSection(streams: [(0x0F, audioPID)]), startsUnit: true)
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(pat + bad + good + pes(adts(1), counter: &counter)))
        #expect(audioBytes(of: events) == adts(1))
    }

    @Test("A duplicated middle packet of a three-packet PMT does not corrupt it")
    func duplicatedPMTContinuation() throws {
        let pat = packet(pid: 0, counter: 0, payload: [0x00] + patSection(), startsUnit: true)
        let long = pmtSection(streams: [(0x0F, audioPID)], programInfo: [UInt8](repeating: 0x05, count: 400))
        let one = packet(pid: pmtPID, counter: 0, payload: [0x00] + Array(long.prefix(183)), startsUnit: true)
        let two = packet(pid: pmtPID, counter: 1, payload: Array(long.dropFirst(183).prefix(184)))
        let three = packet(pid: pmtPID, counter: 2, payload: Array(long.dropFirst(183 + 184)))
        var counter = 0
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(pat + one + two + two + three + pes(adts(1), counter: &counter)))
        #expect(audioBytes(of: events) == adts(1))
    }

    @Test("A resync discards a half-assembled table")
    func resyncDiscardsPartialTable() throws {
        let pat = packet(pid: 0, counter: 0, payload: [0x00] + patSection(), startsUnit: true)
        let long = pmtSection(streams: [(0x03, audioPID)], programInfo: [UInt8](repeating: 0x05, count: 200))
        let head = packet(pid: pmtPID, counter: 0, payload: [0x00] + Array(long.prefix(183)), startsUnit: true)
        let garbage: [UInt8] = [0x10, 0x11]
        let good = packet(pid: pmtPID, counter: 0, payload: [0x00] + pmtSection(streams: [(0x0F, audioPID)]), startsUnit: true)
        var counter = 0
        let events = try TransportStreamAudioDemuxer().demux(
            segment: Data(pat + head + garbage + good + pes(adts(1), counter: &counter) + pes(adts(2), counter: &counter) + pes(adts(3), counter: &counter))
        )
        #expect(audioBytes(of: events) == adts(1) + adts(2) + adts(3))
    }

    @Test("A table head stranded before a resync does not complete from a later continuation")
    func staleTableHeadDoesNotComplete() throws {
        let pat = packet(pid: 0, counter: 0, payload: [0x00] + patSection(), startsUnit: true)
        let long = pmtSection(streams: [(0x03, audioPID)], programInfo: [UInt8](repeating: 0x05, count: 200))
        let head = packet(pid: pmtPID, counter: 0, payload: [0x00] + Array(long.prefix(183)), startsUnit: true)
        let tail = packet(pid: pmtPID, counter: 1, payload: Array(long.dropFirst(183)))
        let garbage: [UInt8] = [0x10, 0x11]
        let good = packet(pid: pmtPID, counter: 2, payload: [0x00] + pmtSection(streams: [(0x0F, audioPID)]), startsUnit: true)
        var counter = 0
        let segment = pat + head + garbage + tail + good + pes(adts(1), counter: &counter) + pes(adts(2), counter: &counter) + pes(adts(3), counter: &counter)
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(segment))
        #expect(audioBytes(of: events) == adts(1) + adts(2) + adts(3))
    }

    @Test("A header inside the damage is not taken for a packet, so the next real packet survives")
    func falseHeaderInGarbage() throws {
        var counter = 0
        let first = pes(adts(1), counter: &counter, declaredLength: true)
        // Starts with a sync byte and the audio PID, as a packet header would.
        let garbage: [UInt8] = [0x47, 0x01, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00]
        counter += 3
        let rest = pes(adts(2), counter: &counter) + pes(adts(3), counter: &counter) + pes(adts(4), counter: &counter)
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(tables() + first + garbage + rest))
        #expect(events == [.audio(Data(adts(1))), .discontinuity, .audio(Data(adts(2) + adts(3) + adts(4)))])
    }

    @Test("A table in progress does not survive an adaptation-field discontinuity")
    func psiAdaptationDiscontinuity() throws {
        let pat = packet(pid: 0, counter: 0, payload: [0x00] + patSection(), startsUnit: true)
        let long = pmtSection(streams: [(0x03, audioPID)], programInfo: [UInt8](repeating: 0x05, count: 200))
        let head = packet(pid: pmtPID, counter: 0, payload: [0x00] + Array(long.prefix(183)), startsUnit: true)
        let flagged = packet(pid: pmtPID, counter: 0, payload: [], discontinuityIndicator: true, withPayload: false)
        let tail = packet(pid: pmtPID, counter: 1, payload: Array(long.dropFirst(183)))
        let good = packet(pid: pmtPID, counter: 2, payload: [0x00] + pmtSection(streams: [(0x0F, audioPID)]), startsUnit: true)
        var counter = 0
        let segment = pat + head + flagged + tail + good + pes(adts(1), counter: &counter)
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(segment))
        #expect(audioBytes(of: events) == adts(1))
    }

    @Test("A PMT that carries the discontinuity flag along with a complete section is still read")
    func flaggedPMTWithPayload() throws {
        let pat = packet(pid: 0, counter: 0, payload: [0x00] + patSection(), startsUnit: true)
        let flagged = packet(pid: pmtPID, counter: 0, payload: [0x00] + pmtSection(streams: [(0x0F, audioPID)]), startsUnit: true, discontinuityIndicator: true)
        var counter = 0
        let events = try TransportStreamAudioDemuxer().demux(segment: Data(pat + flagged + pes(adts(1), counter: &counter)))
        #expect(audioBytes(of: events) == adts(1))
    }

    @Test("After a marked discontinuity the tables are learned again, so a changed audio PID keeps its leading audio")
    func audioPIDChangeAfterDiscontinuity() throws {
        let demuxer = TransportStreamAudioDemuxer()
        var counter = 0
        _ = try demuxer.demux(segment: Data(tables() + pes(adts(1), counter: &counter)))

        demuxer.markDiscontinuity()
        counter = 0
        let newPID = 0x200
        let segment = pes(adts(2), counter: &counter, pid: newPID) + tables(audio: newPID) + pes(adts(3), counter: &counter, pid: newPID)
        let events = try demuxer.demux(segment: Data(segment))
        #expect(events == [.discontinuity, .audio(Data(adts(2) + adts(3)))])
    }
}
