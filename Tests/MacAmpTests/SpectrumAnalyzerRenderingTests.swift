import CoreGraphics
import Foundation
import Testing
@testable import MacAmp

@MainActor
@Suite("Spectrum analyzer rendering")
struct SpectrumAnalyzerRenderingTests {
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 24 distinct sRGB colors, as a skin's visualizer palette supplies them.
    private var colors: [CGColor] {
        (0..<24).map { (i: Int) -> CGColor in
            let red = CGFloat((i * 37) % 256) / 255
            let green = CGFloat((i * 91 + 40) % 256) / 255
            let blue = CGFloat((i * 53 + 7) % 256) / 255
            return CGColor(colorSpace: sRGB, components: [red, green, blue, 1])!
        }
    }

    /// The analyzer drawn with CoreGraphics rect fills into a top-left-origin
    /// context, one pixel per point.
    private func reference(barLevels: [Int], peakLevels: [Int], colors: [CGColor],
                           width: Int, height: Int) -> [UInt32] {
        var pixels = [UInt32](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: sRGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(colors[0])
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(colors[1])
            for x in stride(from: 0, to: Int(VisualizerLayout.width), by: 2) {
                for y in stride(from: 1, to: Int(VisualizerLayout.height), by: 2) {
                    context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            let floor = height - 1
            for row in 0..<15 {
                context.setFillColor(colors[min(17, max(2, 17 - row))])
                for x in barLevels.indices where barLevels[x] > row {
                    context.fill(CGRect(x: x, y: floor - row, width: 1, height: 1))
                }
            }
            context.setFillColor(colors[23])
            for x in peakLevels.indices where peakLevels[x] >= 0 {
                context.fill(CGRect(x: x, y: floor - peakLevels[x], width: 1, height: 1))
            }
        }
        return pixels
    }

    @Test("The bitmap matches CoreGraphics fills pixel for pixel", arguments: [16, 5])
    func matchesCoreGraphics(height: Int) {
        let width = Int(VisualizerLayout.width)
        let barLevels = (0..<75).map { ($0 * 7) % 16 }
        let peakLevels = (0..<75).map { $0 % 5 == 0 ? -1 : min(15, ($0 * 7) % 16 + 2) }
        var pixels = [UInt32](repeating: 0, count: width * height)
        SpectrumAnalyzerNSView.render(
            barLevels: barLevels, peakLevels: peakLevels,
            palette: SpectrumAnalyzerNSView.palette(from: colors),
            width: width, height: height, into: &pixels
        )
        let expected = reference(barLevels: barLevels, peakLevels: peakLevels, colors: colors,
                                 width: width, height: height)
        let mismatches = zip(pixels, expected).filter { $0 != $1 }.count
        #expect(mismatches == 0, "\(mismatches) of \(pixels.count) pixels differ")
    }

    @Test("Missing skin colors fall back to black, and to white for peaks")
    func paletteFallbacks() {
        let palette = SpectrumAnalyzerNSView.palette(from: [])
        #expect(palette[0] == 0xFF00_0000)
        #expect(palette[17] == 0xFF00_0000)
        #expect(palette[23] == 0xFFFF_FFFF)
    }
}
