import AudioToolbox
import Testing
@testable import MacAmp

/// Radio URLs often carry no file extension, so the response's Content-Type
/// is the only source for the parser's format hint.
@Suite("Stream Content-Type hint", .tags(.audio, .parsing))
struct StreamContentTypeHintTests {
    @Test("Content-Type maps to a parser format hint", arguments: [
        ("audio/mpeg", kAudioFileMP3Type),
        ("audio/mp3", kAudioFileMP3Type),
        ("Audio/MPEG; charset=utf-8", kAudioFileMP3Type),
        ("audio/aacp", kAudioFileAAC_ADTSType),
        ("audio/aac", kAudioFileAAC_ADTSType),
        ("audio/x-aac", kAudioFileAAC_ADTSType),
        ("text/html", 0),
        ("", 0),
    ])
    func mapsContentType(contentType: String, expected: AudioFileTypeID) {
        #expect(StreamDecodePipeline.formatHint(forContentType: contentType) == expected)
    }
}
