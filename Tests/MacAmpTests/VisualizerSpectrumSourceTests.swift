import Testing
@testable import MacAmp

/// The tap hears audio after the volume slider and EQ, so only video, which
/// the decoder feed never covers, may draw from it.
@MainActor
@Suite("Spectrum analyzer sources", .tags(.audio))
struct VisualizerSpectrumSourceTests {
    private func pipelineWithTapBatch() -> VisualizerPipeline {
        let pipeline = VisualizerPipeline()
        let width = SpectrumBandAnalyzer.bandCount
        pipeline.updateLevels(
            with: VisualizerData(
                rms: [],
                spectrum: [Float](repeating: 100, count: width),
                spectrumFrameCount: 1,
                spectrumHopDuration: 0.1,
                waveform: [],
                butterchurnSpectrum: [],
                butterchurnWaveform: []
            ),
            useSpectrum: true
        )
        return pipeline
    }

    @Test("Audio with no analyzer frame reads as silence, not as the tap")
    func audioNeverReadsTheTap() {
        let bands = pipelineWithTapBatch().spectrumBands(isPlaying: true, playbackTime: 5, usesTap: false)
        #expect(bands.allSatisfy { $0 == 0 })
    }

    @Test("Video reads the tap")
    func videoReadsTheTap() {
        let bands = pipelineWithTapBatch().spectrumBands(isPlaying: true, playbackTime: 5, usesTap: true)
        #expect(bands.contains { $0 > 0 })
    }
}
