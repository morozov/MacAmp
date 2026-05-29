import Foundation

/// Reads the declared bitrate straight out of an MPEG audio frame header:
/// extract the 4-bit bitrate index and look it up in the Layer III table
/// selected by the header's MPEG version. This is a read, not a
/// measurement — a constant-bitrate stream yields one steady value and a
/// variable-bitrate stream yields the discrete table rate each frame
/// declares.
enum MP3FrameHeader {
    /// Layer III bitrate rows, indexed directly by the header's 4-bit
    /// bitrate field. Index 0 is free format (0 kbps); index 15 is reserved
    /// and rejected before lookup.
    private static let mpeg1LayerIII: [Int] = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    private static let mpeg2LayerIII: [Int] = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]

    /// Declared bitrate in kbps from a big-endian 4-byte frame header.
    /// Returns nil when the 11-bit frame sync is absent, the layer is not
    /// III, the MPEG version is reserved, or the bitrate index is the
    /// reserved value 15. Free format (index 0) returns 0.
    static func bitrateKbps(header: UInt32) -> Int? {
        guard (header & 0xFFE0_0000) == 0xFFE0_0000 else { return nil }
        let layerBits = (header >> 17) & 0x3
        guard layerBits == 0b01 else { return nil }          // 01 = Layer III
        let index = Int((header >> 12) & 0xF)
        guard index != 15 else { return nil }
        switch (header >> 19) & 0x3 {
        case 0b11: return mpeg1LayerIII[index]               // MPEG-1
        case 0b10, 0b00: return mpeg2LayerIII[index]         // MPEG-2 / 2.5
        default: return nil                                  // 01 = reserved
        }
    }
}

/// Declared bitrate as a step function over a track, keyed by frame
/// position. A new step is recorded only where the declared rate changes,
/// so constant-bitrate content collapses to a single entry and the display
/// reads the frame currently playing rather than a windowed average.
struct DeclaredBitrateSteps: Sendable {
    struct Step: Sendable {
        let framePosition: UInt64
        let kbps: Int
    }

    let steps: [Step]

    var isEmpty: Bool { steps.isEmpty }

    /// Declared bitrate in bits/second at `framePosition` — the value of the
    /// last step at or before it — or nil if there are no steps. Bits per
    /// second so the result shares `BitrateSource.currentBitrate`'s units.
    func bitsPerSecond(at framePosition: UInt64) -> Int? {
        guard let first = steps.first else { return nil }
        if framePosition <= first.framePosition { return first.kbps * 1000 }

        // Largest index with steps[i].framePosition <= framePosition.
        var lo = 0
        var hi = steps.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if steps[mid].framePosition <= framePosition {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return steps[lo].kbps * 1000
    }
}
