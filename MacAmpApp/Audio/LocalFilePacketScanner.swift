import Foundation
import AudioToolbox

/// Walks an audio file's packet table and emits `BitrateTracker` markers.
///
/// This is the local-file analogue of the stream pipeline's per-decode
/// marker emission: it gives the shared `BitrateTracker` the same kind of
/// `(framePosition, cumulativeCompressedBytes)` data, just produced
/// up-front from the on-disk packet table instead of incrementally during
/// network decode. Both feeders converge on identical `currentBitrate`
/// behavior — VBR variation visible, CBR steady — without the display
/// having to know what the source is.
enum LocalFilePacketScanner {

    /// Sendable container that crosses the actor boundary from the
    /// background scan task back to the main-actor `BitrateTracker`.
    /// `sampleRate` is the file's source `mSampleRate` (the marker
    /// coordinate system) — `AudioPlayer` uses it as both
    /// `renderSampleRate` and the rate-conversion factor for
    /// `renderFramePosition` so the marker query and the render position
    /// always agree, even when `AVAudioFile.processingFormat.sampleRate`
    /// differs from `mSampleRate` (HE-AAC SBR, etc.).
    struct ScanResult: Sendable {
        let markers: [BitrateTracker.Marker]
        let sampleRate: Float64
        /// Per-frame declared bitrate for MP3 sources, used to drive the
        /// displayed kbps from the frame-header bitrate rather than a
        /// byte-rate average. Nil for non-MP3 formats, which keep the
        /// marker-based windowed readout.
        let declaredBitrate: DeclaredBitrateSteps?
    }

    /// Target spacing between markers, in seconds of audio. ~100 ms keeps
    /// VBR fluctuation perceptible while bounding the marker count on
    /// long files.
    private static let markerStrideSeconds: Double = 0.1


    /// Walk `url`'s packet table and return the marker list plus the file's
    /// sample rate. Returns nil if the file cannot be opened, has no
    /// usable format, or has no enumerable packet table — callers keep
    /// their synchronous seed in those cases rather than overwriting it
    /// with an empty marker list and blanking the display. Safe to call
    /// off the main actor.
    nonisolated static func scan(url: URL) -> ScanResult? {
        var fileID: AudioFileID?
        let openStatus = AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID)
        guard openStatus == noErr, let fileID else { return nil }
        defer { AudioFileClose(fileID) }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: format))
        guard AudioFileGetProperty(fileID, kAudioFilePropertyDataFormat, &size, &format) == noErr,
              format.mSampleRate > 0 else {
            return nil
        }

        var packetCount: UInt64 = 0
        size = UInt32(MemoryLayout<UInt64>.size)
        guard AudioFileGetProperty(fileID, kAudioFilePropertyAudioDataPacketCount, &size, &packetCount) == noErr,
              packetCount > 0 else {
            return nil
        }

        // CBR fast path: every packet has the same size and frame count, so
        // a `(0, 0) → (totalFrames, totalBytes)` pair fully describes the
        // file. `BitrateTracker.bytesAtFramePosition` interpolates between
        // the two markers, yielding the constant bitrate at any in-range
        // render position — no per-packet walk needed.
        if format.mBytesPerPacket > 0 && format.mFramesPerPacket > 0 {
            let totalFrames = packetCount &* UInt64(format.mFramesPerPacket)
            let totalBytes = packetCount &* UInt64(format.mBytesPerPacket)
            return ScanResult(
                markers: [
                    .init(framePosition: 0, cumulativeCompressedBytes: 0),
                    .init(framePosition: totalFrames, cumulativeCompressedBytes: totalBytes),
                ],
                sampleRate: format.mSampleRate,
                declaredBitrate: nil
            )
        }

        // VBR path: read packet descriptions in batches and accumulate.
        var maxPacketSize: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioFileGetProperty(fileID, kAudioFilePropertyMaximumPacketSize, &size, &maxPacketSize) == noErr,
              maxPacketSize > 0 else {
            return nil
        }

        let readBatchPackets: UInt32 = 256
        let bufferSize = Int(maxPacketSize) * Int(readBatchPackets)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
        defer { buffer.deallocate() }
        let descs = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: Int(readBatchPackets))
        defer { descs.deallocate() }

        // Approximate per-packet stride. We don't yet know each packet's
        // exact frame count (mVariableFramesInPacket is per-packet) but
        // mFramesPerPacket carries the nominal value the container declares
        // for VBR formats (e.g. 1152 for MP3, 1024 for AAC). Fall back to
        // 1024 if the container leaves it 0.
        let nominalFramesPerPacket = format.mFramesPerPacket > 0
            ? Double(format.mFramesPerPacket)
            : 1024.0
        let stride = max(1, Int((markerStrideSeconds * format.mSampleRate / nominalFramesPerPacket).rounded()))

        var markers: [BitrateTracker.Marker] = []
        markers.reserveCapacity(Int(packetCount) / stride + 2)
        markers.append(.init(framePosition: 0, cumulativeCompressedBytes: 0))

        // For MP3, read the declared bitrate out of each frame header,
        // recording a step only where the rate changes.
        let isMP3 = format.mFormatID == kAudioFormatMPEGLayer3
        var declaredSteps: [DeclaredBitrateSteps.Step] = []
        var lastDeclaredKbps = -1

        var packetIdx: UInt64 = 0
        var cumulativeFrames: UInt64 = 0
        var cumulativeBytes: UInt64 = 0
        var sinceLastMarker = 0

        while packetIdx < packetCount {
            var numBytes: UInt32 = UInt32(bufferSize)
            var numPackets: UInt32 = min(readBatchPackets, UInt32(packetCount - packetIdx))
            let readStatus = AudioFileReadPacketData(
                fileID,
                false,
                &numBytes,
                descs,
                Int64(packetIdx),
                &numPackets,
                buffer
            )
            guard (readStatus == noErr || readStatus == kAudioFileEndOfFileError),
                  numPackets > 0 else { break }

            for i in 0..<Int(numPackets) {
                let desc = descs[i]
                cumulativeBytes &+= UInt64(desc.mDataByteSize)
                // Same fallback chain as `stride`: if a malformed file
                // leaves both per-packet sources at 0, fall back to a
                // typical packet size so positions still advance.
                let framesInPacket: UInt64
                if desc.mVariableFramesInPacket > 0 {
                    framesInPacket = UInt64(desc.mVariableFramesInPacket)
                } else if format.mFramesPerPacket > 0 {
                    framesInPacket = UInt64(format.mFramesPerPacket)
                } else {
                    framesInPacket = UInt64(nominalFramesPerPacket)
                }
                if isMP3, desc.mDataByteSize >= 4 {
                    let p = buffer.advanced(by: Int(desc.mStartOffset))
                    let header = (UInt32(p.load(fromByteOffset: 0, as: UInt8.self)) << 24)
                        | (UInt32(p.load(fromByteOffset: 1, as: UInt8.self)) << 16)
                        | (UInt32(p.load(fromByteOffset: 2, as: UInt8.self)) << 8)
                        | UInt32(p.load(fromByteOffset: 3, as: UInt8.self))
                    if let kbps = MP3FrameHeader.bitrateKbps(header: header), kbps != lastDeclaredKbps {
                        declaredSteps.append(.init(framePosition: cumulativeFrames, kbps: kbps))
                        lastDeclaredKbps = kbps
                    }
                }
                cumulativeFrames &+= framesInPacket
                sinceLastMarker += 1
                if sinceLastMarker >= stride {
                    markers.append(.init(
                        framePosition: cumulativeFrames,
                        cumulativeCompressedBytes: cumulativeBytes
                    ))
                    sinceLastMarker = 0
                }
            }

            packetIdx &+= UInt64(numPackets)
        }

        // Always cap with a marker at the file's end so the last query
        // window — which may straddle the final stride boundary — still has
        // an upper anchor to read against.
        if sinceLastMarker > 0 {
            markers.append(.init(
                framePosition: cumulativeFrames,
                cumulativeCompressedBytes: cumulativeBytes
            ))
        }

        return ScanResult(
            markers: markers,
            sampleRate: format.mSampleRate,
            declaredBitrate: declaredSteps.isEmpty ? nil : DeclaredBitrateSteps(steps: declaredSteps)
        )
    }
}
