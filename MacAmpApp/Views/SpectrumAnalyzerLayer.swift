import AppKit
import QuartzCore
import SwiftUI

/// Draws the spectrum analyzer, and owns the fall model that drives it.
///
/// The model advances on the display link and the result goes straight to
/// `setNeedsDisplay`, so a running analyzer never touches SwiftUI state. State
/// that changes every refresh marks the window's hosting view dirty, and the
/// layout pass that follows walks the whole view tree — far more expensive, in
/// a window this size, than anything the analyzer draws.
@MainActor
final class SpectrumAnalyzerNSView: NSView {
    /// Latest band levels, 0...255 per column, and whether audio is rendering.
    var bandsProvider: (() -> [Float])?
    var isRenderingProvider: (() -> Bool)?

    /// Colors 0...23 from the skin's visualizer palette.
    var colors: [CGColor] = [] {
        didSet {
            palette = Self.palette(from: colors)
            needsDisplay = true
        }
    }

    // MARK: - Analyzer configuration

    private static let columnCount = 75
    private static let maxLevel = 15
    private let peaksEnabled = true

    // Falloff presets, slowest to fastest, in per-tick units: bars drop by a
    // fixed number of 1/16-level units per tick, and each tick scales a peak
    // cap's downward velocity by its multiplier. Indices are the analyzer's two
    // falloff settings; both are pinned to the fastest preset here.
    private static let barFalloffPresets = [3, 6, 12, 16, 32]
    private static let peakFalloffPresets: [Float] = [1.05, 1.1, 1.2, 1.4, 1.6]
    private let barFalloff = barFalloffPresets[4]
    private let peakFalloff = peakFalloffPresets[4]
    private let peakInitialVelocity: Float = 3.0

    // The falloff presets are per-tick quantities calibrated to a 62.5 Hz fall
    // model, a rate no display refresh is obliged to match, so a refresh
    // advances the model by the whole ticks that have elapsed since the last.
    private static let fallTickInterval: CFTimeInterval = 1.0 / 62.5
    private static let maxTicksPerFrame = 4

    // MARK: - Fall model state

    private var barFixed = [Int](repeating: 0, count: columnCount)
    private var peakFixed = [Int](repeating: 0, count: columnCount)
    private var peakVelocity = [Float](repeating: 0, count: columnCount)
    private var barLevels = [Int](repeating: 0, count: columnCount)
    private var peakLevels = [Int](repeating: -1, count: columnCount)

    private var lastFallTick: CFTimeInterval = 0
    private var fallTickCredit: CFTimeInterval = 0
    private var link: CADisplayLink?

    private var palette = SpectrumAnalyzerNSView.palette(from: [])
    /// The frame's bitmap, reused across frames.
    private var pixels: [UInt32] = []

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Display link

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // The link retains its target, so leaving it running on an unparented
        // view keeps both alive; invalidating here is what breaks the cycle.
        guard window != nil else {
            link?.invalidate()
            link = nil
            return
        }

        guard link == nil else { return }
        let created = displayLink(target: self, selector: #selector(tick))
        created.add(to: .main, forMode: .common)
        link = created
    }

    @objc private func tick() {
        guard isRenderingProvider?() == true else {
            if resetModel() { needsDisplay = true }
            return
        }

        guard let bands = bandsProvider?(), bands.count >= Self.columnCount else { return }

        let ticks = elapsedFallTicks()
        guard ticks > 0 else { return }

        var changed = false
        for _ in 0..<ticks {
            for x in 0..<Self.columnCount {
                // Band levels arrive on a 0...255 scale; the analyzer keeps the
                // bottom 16 of it and saturates above.
                var v = min(Self.maxLevel, max(0, Int(bands[x])))

                // Bar falloff: drop by a fixed step per tick, snap up to a new hit.
                if (v << 4) < barFixed[x] {
                    barFixed[x] = max(0, barFixed[x] - barFalloff)
                    v = barFixed[x] >> 4
                } else {
                    barFixed[x] = v << 4
                }

                // Peak cap: snap to the bar top on a fresh hit, then accelerate down.
                if peakFixed[x] <= v * 256 {
                    peakFixed[x] = v * 256
                    peakVelocity[x] = peakInitialVelocity
                }
                let level = peakFixed[x] / 256
                let cap = (peaksEnabled && level >= 0 && level <= Self.maxLevel) ? level : -1
                peakFixed[x] -= Int(peakVelocity[x])
                peakVelocity[x] *= peakFalloff
                if peakFixed[x] < 0 { peakFixed[x] = 0 }

                if barLevels[x] != v { barLevels[x] = v; changed = true }
                if peakLevels[x] != cap { peakLevels[x] = cap; changed = true }
            }
        }

        if changed { needsDisplay = true }
    }

    /// Whole fall-model ticks owed since the previous frame, keeping the
    /// sub-tick remainder so the average rate holds over time.
    private func elapsedFallTicks() -> Int {
        let now = CACurrentMediaTime()
        let elapsed = lastFallTick > 0 ? now - lastFallTick : Self.fallTickInterval
        lastFallTick = now

        // Cap the debt: a stall must not repay as a burst of ticks that drops
        // every bar and cap to the floor in one frame.
        fallTickCredit = min(fallTickCredit + elapsed,
                             CFTimeInterval(Self.maxTicksPerFrame) * Self.fallTickInterval)
        let ticks = Int(fallTickCredit / Self.fallTickInterval)
        fallTickCredit -= CFTimeInterval(ticks) * Self.fallTickInterval
        return ticks
    }

    /// Clear the model; returns whether anything was showing.
    @discardableResult
    private func resetModel() -> Bool {
        lastFallTick = 0
        fallTickCredit = 0
        var wasShowing = false
        for x in 0..<Self.columnCount {
            if barLevels[x] != 0 || peakLevels[x] != -1 { wasShowing = true }
            barFixed[x] = 0
            peakFixed[x] = 0
            peakVelocity[x] = 0
            barLevels[x] = 0
            peakLevels[x] = -1
        }
        return wasShowing
    }

    // MARK: - Drawing

    override func updateLayer() {
        guard let layer else { return }
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0 else { return }
        if pixels.count != width * height {
            pixels = [UInt32](repeating: 0, count: width * height)
        }
        Self.render(barLevels: barLevels, peakLevels: peakLevels, palette: palette,
                    width: width, height: height, into: &pixels)
        layer.magnificationFilter = .nearest
        layer.contents = Self.image(from: pixels, width: width, height: height)
    }

    /// Visualizer colors 0...23 as sRGB RGBA bytes in memory order, black where
    /// the skin supplies none and white for a missing peak color.
    static func palette(from colors: [CGColor]) -> [UInt32] {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        func pack(_ color: CGColor) -> UInt32 {
            guard let c = color.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components,
                  c.count == 4 else { return 0xFF00_0000 }
            let bytes = c.map { UInt32((min(1, max(0, $0)) * 255).rounded()) }
            return bytes[0] | bytes[1] << 8 | bytes[2] << 16 | bytes[3] << 24
        }
        return (0..<24).map { index in
            if colors.indices.contains(index) { return pack(colors[index]) }
            return index == 23 ? 0xFFFF_FFFF : 0xFF00_0000
        }
    }

    /// Renders the analyzer one pixel per point, top row first, into `pixels`,
    /// which holds `width * height` colors from `palette`.
    static func render(barLevels: [Int], peakLevels: [Int], palette: [UInt32],
                       width: Int, height: Int, into pixels: inout [UInt32]) {
        pixels.withUnsafeMutableBufferPointer { buffer in
            func plot(_ x: Int, _ y: Int, _ color: UInt32) {
                guard x >= 0, x < width, y >= 0, y < height else { return }
                buffer[y * width + x] = color
            }
            buffer.update(repeating: palette[0])
            for x in stride(from: 0, to: Int(VisualizerLayout.width), by: 2) {
                for y in stride(from: 1, to: Int(VisualizerLayout.height), by: 2) {
                    plot(x, y, palette[1])
                }
            }
            let floor = height - 1
            for x in 0..<min(columnCount, barLevels.count, peakLevels.count) {
                for row in 0..<min(barLevels[x], maxLevel) {
                    plot(x, floor - row, palette[min(17, max(2, 17 - row))])
                }
                if peakLevels[x] >= 0 {
                    plot(x, floor - peakLevels[x], palette[23])
                }
            }
        }
    }

    private static func image(from pixels: [UInt32], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: pixels.withUnsafeBytes { Data($0) } as CFData)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// Hosts the analyzer in SwiftUI. The view below redraws itself off the display
/// link, so nothing here updates once it is installed except the palette.
struct SpectrumAnalyzerLayer: NSViewRepresentable {
    let colors: [Color]
    let bands: () -> [Float]
    let isRendering: () -> Bool
    var help: String?

    func makeNSView(context: Context) -> SpectrumAnalyzerNSView {
        let view = SpectrumAnalyzerNSView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: SpectrumAnalyzerNSView, context: Context) {
        configure(nsView)
    }

    func configure(_ nsView: SpectrumAnalyzerNSView) {
        nsView.toolTip = help
        nsView.bandsProvider = bands
        nsView.isRenderingProvider = isRendering
        let resolved = Self.cgColors(from: colors)
        if resolved != nsView.colors {
            nsView.colors = resolved
        }
    }

    private static func cgColors(from colors: [Color]) -> [CGColor] {
        colors.map { NSColor($0).usingColorSpace(.sRGB)?.cgColor ?? CGColor(gray: 0, alpha: 1) }
    }
}
