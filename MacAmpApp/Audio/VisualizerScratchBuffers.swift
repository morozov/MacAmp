import Accelerate
import Foundation

// MARK: - Scratch Buffers

/// Per-tap audio-thread scratch buffers. One instance per render thread / tap.
///
/// Scratch buffers are confined to a single audio render thread, so
/// `@unchecked Sendable` is safe: there are no cross-thread accesses to
/// internal state. The producing thread runs RMS bucketing, the spectrum
/// analyzer, and the 2048-pt Butterchurn FFT into these pre-allocated buffers,
/// then publishes the results via `VisualizerFeed.tryPublish(from:)`.
///
/// **Producers:** the engine-side `mainMixerNode` tap and the video-side
/// `MTAudioProcessingTap` render path.
/// Each tap allocates its own instance at attach time and reuses it for the
/// lifetime of the tap — never shared across taps.
final class VisualizerScratchBuffers: @unchecked Sendable {
    private(set) var mono: [Float] = []
    private(set) var rms: [Float] = []
    private(set) var spectrum: [Float] = []

    // Newest mono samples, oldest first. Every transform below reads a window
    // out of here rather than out of the callback, so a delivery's size decides
    // only how much new audio arrived, never the shape of a window. It holds a
    // full delivery plus the extra leading samples the oldest window of that
    // delivery needs.
    private(set) var history: [Float] = Array(repeating: 0, count: maxFrameCount + analyzerFFTSize)
    private var butterchurnPending = 0

    // Spectrum analyzer: a 512-point transform stepped every 256 samples, each
    // folded into 75 bands.
    static let spectrumBandCount = 75
    static let analyzerHop = 256
    private static let analyzerFFTSize = 512
    private static let analyzerBins = analyzerFFTSize / 2
    /// Frames one delivery can produce, at the smallest hop over the largest
    /// delivery.
    static let maxSpectrumFrames = maxFrameCount / analyzerHop + 1

    private(set) var spectrumFrameCount = 0

    private var analyzerWindow: [Float] = Array(repeating: 0, count: analyzerFFTSize)
    private var analyzerWindowed: [Float] = Array(repeating: 0, count: analyzerFFTSize)
    private var analyzerInputReal: [Float] = Array(repeating: 0, count: analyzerBins)
    private var analyzerInputImag: [Float] = Array(repeating: 0, count: analyzerBins)
    private var analyzerOutputReal: [Float] = Array(repeating: 0, count: analyzerBins)
    private var analyzerOutputImag: [Float] = Array(repeating: 0, count: analyzerBins)
    private var analyzerMagnitudes: [Float] = Array(repeating: 0, count: analyzerBins)
    private let analyzerSetup: vDSP_DFT_Setup?

    // Butterchurn FFT buffers
    private static let butterchurnFFTSize: Int = 2048
    private static let butterchurnBins: Int = 1024

    private var butterchurnReal: [Float] = Array(repeating: 0, count: butterchurnFFTSize)
    private var butterchurnImag: [Float] = Array(repeating: 0, count: butterchurnFFTSize)
    private(set) var butterchurnSpectrum: [Float] = Array(repeating: 0, count: butterchurnBins)
    private(set) var butterchurnWaveform: [Float] = Array(repeating: 0, count: butterchurnBins)

    // Pre-allocated FFT working buffers (avoid per-buffer allocations on audio thread)
    private var hannWindow: [Float] = Array(repeating: 0, count: butterchurnFFTSize)
    private var fftInputReal: [Float] = Array(repeating: 0, count: butterchurnFFTSize / 2)
    private var fftInputImag: [Float] = Array(repeating: 0, count: butterchurnFFTSize / 2)
    private var fftOutputReal: [Float] = Array(repeating: 0, count: butterchurnFFTSize / 2)
    private var fftOutputImag: [Float] = Array(repeating: 0, count: butterchurnFFTSize / 2)

    // vDSP FFT setup (log2(2048) = 11)
    private let fftSetup: vDSP_DFT_Setup?

    // Pre-allocated capacity to avoid reallocation on frame-size changes. A tap
    // delivers at least 100 ms per callback, which is 4410 frames at 44.1 kHz
    // and 4800 at 48 kHz; anything shorter than the delivery would drop the
    // tail of every buffer and leave gaps in the history.
    private static let maxFrameCount = 8192
    private static let maxBars = 20

    init() {
        // Create FFT setup for 2048-point real-to-complex transform
        fftSetup = vDSP_DFT_zrop_CreateSetup(
            nil,
            vDSP_Length(Self.butterchurnFFTSize),
            .FORWARD
        )

        analyzerSetup = vDSP_DFT_zrop_CreateSetup(
            nil,
            vDSP_Length(Self.analyzerFFTSize),
            .FORWARD
        )

        // Pre-compute Hann window (never changes)
        vDSP_hann_window(&hannWindow, vDSP_Length(Self.butterchurnFFTSize), Int32(vDSP_HANN_NORM))

        // Periodic Hann, peak 1.0: the analyzer's band scale is calibrated to a
        // window of unit amplitude, so this one is built rather than taken from
        // vDSP_hann_window's normalized variant.
        for n in 0..<Self.analyzerFFTSize {
            analyzerWindow[n] = 0.5 * (1 - cos(2 * Float.pi * Float(n) / Float(Self.analyzerFFTSize)))
        }

        // Pre-allocate buffers at max capacity to avoid reallocation
        mono = Array(repeating: 0, count: Self.maxFrameCount)
        rms = Array(repeating: 0, count: Self.maxBars)
        spectrum = Array(repeating: 0, count: Self.maxSpectrumFrames * Self.spectrumBandCount)
    }

    deinit {
        if let setup = fftSetup {
            vDSP_DFT_DestroySetup(setup)
        }
        if let setup = analyzerSetup {
            vDSP_DFT_DestroySetup(setup)
        }
    }

    func prepare(frameCount: Int) -> Int {
        // CRITICAL: Never allocate on audio thread. Clamp to pre-allocated capacity
        // instead of growing buffers. AVAudioEngine buffer size is 2048, well within
        // our 4096 cap, so this clamp should never activate in normal operation.
        let cappedFrameCount = min(frameCount, mono.count)

        mono.withUnsafeMutableBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            vDSP_vclr(baseAddress, 1, vDSP_Length(cappedFrameCount))
        }

        return cappedFrameCount
    }

    func withMono<R>(_ body: (inout [Float]) -> R) -> R {
        body(&mono)
    }

    func withMonoReadOnly<R>(_ body: ([Float]) -> R) -> R {
        body(mono)
    }

    func withRms<R>(_ body: (inout [Float]) -> R) -> R {
        body(&rms)
    }

    func withSpectrum<R>(_ body: (inout [Float]) -> R) -> R {
        body(&spectrum)
    }

    // MARK: - Sample History

    /// Append the first `count` mono samples to the rolling history, evicting
    /// the oldest.
    func appendHistory(count: Int) {
        let size = history.count
        let n = min(count, mono.count)
        guard n > 0 else { return }

        butterchurnPending += n

        if n >= size {
            let start = n - size
            for i in 0..<size {
                history[i] = mono[start + i]
            }
            return
        }

        let keep = size - n
        for i in 0..<keep {
            history[i] = history[i + n]
        }
        for i in 0..<n {
            history[keep + i] = mono[i]
        }
    }

    /// Whether a full Butterchurn window of samples has arrived since this last
    /// returned true, resetting the count when it does.
    ///
    /// Its transform costs four times the analyzer's and feeds a consumer that
    /// reads one frame per window at most, so it stays on the window's own
    /// cadence rather than the tap's.
    func takeButterchurnRefresh() -> Bool {
        guard butterchurnPending >= Self.butterchurnFFTSize else { return false }
        butterchurnPending = 0
        return true
    }

    // MARK: - Spectrum Analyzer

    /// Recompute `spectrum` as one frame per hop across the newest `newSamples`
    /// samples of history, oldest frame first.
    ///
    /// Each frame is 75 band levels on a 0...255 byte scale, exponentially
    /// spaced at twelve bands per octave. Bands below the first FFT bin's width
    /// share interpolated values; bands wider than one bin total the bins they
    /// cover, so a level is proportional to the energy in the band, not to its
    /// average.
    func updateSpectrum(newSamples: Int) {
        let hop = Self.analyzerHop
        let frames = min(Self.maxSpectrumFrames, max(1, (newSamples + hop - 1) / hop))
        spectrumFrameCount = frames

        for frame in 0..<frames {
            // Frame 0 is the oldest; the last one ends on the newest sample.
            let end = history.count - (frames - 1 - frame) * hop
            analyzeWindow(endingAt: end, into: frame * Self.spectrumBandCount)
        }
    }

    private func analyzeWindow(endingAt end: Int, into destination: Int) {
        guard let setup = analyzerSetup else { return }

        let size = Self.analyzerFFTSize
        let offset = max(0, end - size)

        // The tap averages the channels; this analyzer's input is their sum.
        for i in 0..<size {
            analyzerWindowed[i] = history[offset + i] * 2
        }
        vDSP_vmul(analyzerWindowed, 1, analyzerWindow, 1, &analyzerWindowed, 1, vDSP_Length(size))

        for i in 0..<Self.analyzerBins {
            analyzerInputReal[i] = analyzerWindowed[i * 2]
            analyzerInputImag[i] = analyzerWindowed[i * 2 + 1]
        }
        vDSP_DFT_Execute(setup, analyzerInputReal, analyzerInputImag, &analyzerOutputReal, &analyzerOutputImag)

        // Half of this scale is the analyzer's own; the other half undoes vDSP's
        // convention of returning twice the unnormalized transform for a
        // real-to-complex pass.
        let magnitudeScale: Float = 0.25
        for i in 0..<Self.analyzerBins {
            let real = analyzerOutputReal[i]
            let imag = analyzerOutputImag[i]
            analyzerMagnitudes[i] = sqrt(real * real + imag * imag) * magnitudeScale
        }

        mapSpectrumBands(into: destination)
    }

    /// 4-point, 3rd-order Hermite interpolation of a magnitude at a fractional
    /// bin position `x` between `y1` and `y2`.
    private static func hermite(_ x: Float, _ y0: Float, _ y1: Float, _ y2: Float, _ y3: Float) -> Float {
        let c0 = y1
        let c1 = 0.5 * (y2 - y0)
        let c3 = 1.5 * (y1 - y2) + 0.5 * (y3 - y0)
        let c2 = y0 - y1 + c1 - c3
        return ((c3 * x + c2) * x + c1) * x + c0
    }

    /// Fold `analyzerMagnitudes` into the 75 exponentially spaced bands starting
    /// at `destination` in `spectrum`.
    private func mapSpectrumBands(into destination: Int) {
        let bins = Self.analyzerBins
        let bands = Self.spectrumBandCount

        // Band edges run from bin 1 up to bin 253, doubling every twelve bands.
        let span = 255 / exp2(Float(bands) / 12)
        func edge(_ band: Int) -> Float { (exp2(Float(band) / 12) - 1) * span + 1 }

        var next = edge(0)
        for x in 0..<bands {
            var binF = next
            next = edge(x + 1)

            var bin = Int(binF)
            let end = min(Int(next), bins - 1)
            var mult = Float(bin + 1) - binF
            var interpolate = true
            var total: Float = 0

            repeat {
                if bin == end {
                    mult = next - binF
                    interpolate = true
                }
                if interpolate {
                    let c = bin < bins - 1 ? analyzerMagnitudes[bin + 1] : 0
                    let d = bin < bins - 2 ? analyzerMagnitudes[bin + 2] : 0
                    let value = Self.hermite(binF - Float(bin), analyzerMagnitudes[bin - 1], analyzerMagnitudes[bin], c, d)
                    total += value * mult
                } else {
                    total += analyzerMagnitudes[bin]
                }
                interpolate = false
                bin += 1
                binF = Float(bin)
            } while bin <= end

            // The interpolation can overshoot past a steep edge, so the low end
            // needs a floor as much as the high end needs a ceiling.
            spectrum[destination + x] = min(max(total, 0), 255).rounded(.towardZero)
        }
    }

    // MARK: - Butterchurn FFT Processing

    /// Recompute the Butterchurn spectrum and waveform from the full sample history.
    /// - Note: Uses pre-allocated buffers to avoid audio-thread allocations
    func processButterchurnFFT() {
        guard let setup = fftSetup else { return }

        let sampleCount = Self.butterchurnFFTSize
        let base = history.count - sampleCount
        for i in 0..<sampleCount {
            butterchurnReal[i] = history[base + i]
        }

        // Apply pre-computed Hann window to reduce spectral leakage
        vDSP_vmul(butterchurnReal, 1, hannWindow, 1, &butterchurnReal, 1, vDSP_Length(Self.butterchurnFFTSize))

        // Prepare split complex for FFT using pre-allocated buffers
        // For real-to-complex DFT, input is interleaved as even/odd
        for i in 0..<(Self.butterchurnFFTSize / 2) {
            fftInputReal[i] = butterchurnReal[i * 2]
            fftInputImag[i] = butterchurnReal[i * 2 + 1]
        }

        // Execute FFT into pre-allocated output buffers
        vDSP_DFT_Execute(setup, fftInputReal, fftInputImag, &fftOutputReal, &fftOutputImag)

        // Compute magnitude spectrum (first 1024 bins)
        // Magnitude = sqrt(real² + imag²)
        for i in 0..<Self.butterchurnBins {
            let real = fftOutputReal[i % fftOutputReal.count]
            let imag = fftOutputImag[i % fftOutputImag.count]
            var magnitude = sqrt(real * real + imag * imag)

            // Normalize and scale for visualization (0-1 range)
            magnitude /= Float(Self.butterchurnFFTSize)
            magnitude = min(1.0, magnitude * 4.0)  // Boost for visibility

            butterchurnSpectrum[i] = magnitude
        }

        // Capture waveform: downsample to 1024 samples
        let step = max(1, sampleCount / Self.butterchurnBins)
        for i in 0..<Self.butterchurnBins {
            let sampleIndex = min(i * step, sampleCount - 1)
            butterchurnWaveform[i] = history[base + sampleIndex]
        }
    }
}
