import AudioToolbox
import Foundation
import Testing
@testable import MacAmp

/// HE-AAC carries its high frequencies in an SBR layer that only the full
/// HE-AAC format decodes; the stream's plain data format describes the core
/// AAC layer at half the sample rate.
@Suite("Stream format selection", .tags(.audio, .parsing))
struct StreamFormatSelectionTests {
    private final class BundleToken {}

    private func asbd(_ id: AudioFormatID, _ rate: Float64) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: id, mFormatFlags: 0, mBytesPerPacket: 0,
                                    mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: 2,
                                    mBitsPerChannel: 0, mReserved: 0)
    }

    @Test("The first decodable entry of the format list wins over the data format")
    func prefersFirstDecodableListEntry() {
        let items = [kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC].map {
            AudioFormatListItem(mASBD: asbd($0, $0 == kAudioFormatMPEG4AAC ? 22050 : 44100), mChannelLayoutTag: 0)
        }
        let core = asbd(kAudioFormatMPEG4AAC, 22050)

        let chosen = AudioFileStreamParser.preferredFormat(
            in: items, fallback: core, decodable: [kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC])
        #expect(chosen.mFormatID == kAudioFormatMPEG4AAC_HE)
        #expect(chosen.mSampleRate == 44100)

        #expect(AudioFileStreamParser.preferredFormat(in: [], fallback: core, decodable: []).mFormatID == kAudioFormatMPEG4AAC)
    }

    @Test("The HE-AAC format is chosen when the stream arrives in small pieces")
    func heAACChosenFromChunkedStream() throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "he-aac", withExtension: "aac"))
        let bytes = try Data(contentsOf: url)

        var formats: [AudioStreamBasicDescription] = []
        let parser = AudioFileStreamParser(formatHint: 0)
        parser.onFormatAvailable = { formats.append($0) }
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 7, bytes.count)
            parser.parse(bytes.subdata(in: offset..<end))
            offset = end
        }

        #expect(formats.count == 1)
        #expect(formats.first?.mFormatID == kAudioFormatMPEG4AAC_HE)
        #expect(formats.first?.mSampleRate == 48000)
    }

    @Test("An HE-AAC stream decodes at its full rate with its high frequencies")
    func heAACDecodesWithSBR() throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "he-aac", withExtension: "aac"))
        let bytes = try Data(contentsOf: url)

        var format: AudioStreamBasicDescription?
        var packets: [(Data, [AudioStreamPacketDescription])] = []
        let parser = AudioFileStreamParser(formatHint: kAudioFileAAC_ADTSType)
        parser.onFormatAvailable = { format = $0 }
        parser.onPackets = { packets.append(($0, $1)) }
        parser.parse(bytes)

        let input = try #require(format)
        #expect(input.mFormatID == kAudioFormatMPEG4AAC_HE)
        #expect(input.mSampleRate == 48000)

        // The fixture is a 15 kHz tone, above the 12 kHz ceiling of the 24 kHz core layer.
        let decoder = AudioConverterDecoder(inputFormat: input)
        for (data, descriptions) in packets {
            for desc in descriptions {
                let packet = data[Int(desc.mStartOffset)..<Int(desc.mStartOffset) + Int(desc.mDataByteSize)]
                var single = desc
                single.mStartOffset = 0
                decoder.enqueue(data: Data(packet), descriptions: [single])
            }
        }
        var sumOfSquares = 0.0
        var samples = 0
        while decoder.hasQueuedPackets, let (pcm, frames) = decoder.decode() {
            for i in 0..<frames * 2 { sumOfSquares += Double(pcm[i] * pcm[i]) }
            samples += frames * 2
        }
        #expect(decoder.sampleRate == 48000)
        #expect(samples > 0)
        #expect((sumOfSquares / Double(max(samples, 1))).squareRoot() > 0.01, "the 15 kHz tone should survive decoding")
    }
}
