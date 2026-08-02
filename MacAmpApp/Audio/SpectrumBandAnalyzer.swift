import Accelerate
import Foundation

/// Folds mono audio into the 75 band levels the spectrum analyzer draws.
///
/// A caller supplies a run of samples and the index one past the newest sample
/// it wants analyzed; the transform reads the window ending there. Levels come
/// out on a 0...255 scale, exponentially spaced at twelve bands per octave, and
/// each band totals the bins it spans, so a level is proportional to the energy
/// in the band rather than to its average.
///
/// Instances own pre-allocated working buffers and are not thread-safe: confine
/// one to whichever queue feeds it.
final class SpectrumBandAnalyzer {
    static let bandCount = 75
    /// Samples per transform.
    static let windowSize = 512
    /// Samples between consecutive windows.
    static let hop = 256

    private static let bins = windowSize / 2

    private var window: [Float] = Array(repeating: 0, count: windowSize)
    private var windowed: [Float] = Array(repeating: 0, count: windowSize)
    private var inputReal: [Float] = Array(repeating: 0, count: bins)
    private var inputImag: [Float] = Array(repeating: 0, count: bins)
    private var outputReal: [Float] = Array(repeating: 0, count: bins)
    private var outputImag: [Float] = Array(repeating: 0, count: bins)
    private var magnitudes: [Float] = Array(repeating: 0, count: bins)
    private let setup: vDSP_DFT_Setup?

    init() {
        setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(Self.windowSize), .FORWARD)

        // Periodic Hann, peak 1.0: the band scale below is calibrated to a
        // window of unit amplitude.
        for n in 0..<Self.windowSize {
            window[n] = 0.5 * (1 - cos(2 * Float.pi * Float(n) / Float(Self.windowSize)))
        }
    }

    deinit {
        if let setup {
            vDSP_DFT_DestroySetup(setup)
        }
    }

    /// Analyze the window ending at `end` and write 75 levels into `bands`
    /// starting at `destination`.
    ///
    /// - Parameters:
    ///   - samples: Mono samples, each the average of its frame's channels.
    ///   - end: Index one past the newest sample to include. Samples before the
    ///     start of `samples` read as silence.
    func analyze(_ samples: [Float], endingAt end: Int, into bands: inout [Float], at destination: Int) {
        guard let setup else { return }

        let size = Self.windowSize
        let start = end - size

        // The caller averages the channels; the analyzer's input is their sum.
        for i in 0..<size {
            let index = start + i
            windowed[i] = (index >= 0 && index < samples.count) ? samples[index] * 2 : 0
        }
        vDSP_vmul(windowed, 1, window, 1, &windowed, 1, vDSP_Length(size))

        for i in 0..<Self.bins {
            inputReal[i] = windowed[i * 2]
            inputImag[i] = windowed[i * 2 + 1]
        }
        vDSP_DFT_Execute(setup, inputReal, inputImag, &outputReal, &outputImag)

        // Half of this scale is the analyzer's own; the other half undoes vDSP's
        // convention of returning twice the unnormalized transform for a
        // real-to-complex pass.
        let magnitudeScale: Float = 0.25
        for i in 0..<Self.bins {
            let real = outputReal[i]
            let imag = outputImag[i]
            magnitudes[i] = sqrt(real * real + imag * imag) * magnitudeScale
        }

        mapBands(into: &bands, at: destination)
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

    private func mapBands(into bands: inout [Float], at destination: Int) {
        let bins = Self.bins
        let count = Self.bandCount

        // Band edges run from bin 1 up to bin 253, doubling every twelve bands.
        let span = 255 / exp2(Float(count) / 12)
        func edge(_ band: Int) -> Float { (exp2(Float(band) / 12) - 1) * span + 1 }

        var next = edge(0)
        for x in 0..<count {
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
                    let c = bin < bins - 1 ? magnitudes[bin + 1] : 0
                    let d = bin < bins - 2 ? magnitudes[bin + 2] : 0
                    total += Self.hermite(binF - Float(bin), magnitudes[bin - 1], magnitudes[bin], c, d) * mult
                } else {
                    total += magnitudes[bin]
                }
                interpolate = false
                bin += 1
                binF = Float(bin)
            } while bin <= end

            // The interpolation can overshoot past a steep edge, so the low end
            // needs a floor as much as the high end needs a ceiling.
            bands[destination + x] = min(max(total, 0), 255).rounded(.towardZero)
        }
    }
}
