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
        didSet { needsDisplay = true }
    }

    // MARK: - Analyzer configuration

    private static let columnCount = 75
    private let maxLevel = 15
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

    /// Reused per draw so a frame allocates nothing.
    private var rowRects = [CGRect]()
    private var peakRects = [CGRect]()
    private lazy var gridRects: [CGRect] = {
        var rects: [CGRect] = []
        for x in stride(from: 0, to: Int(VisualizerLayout.width), by: 2) {
            for y in stride(from: 1, to: Int(VisualizerLayout.height), by: 2) {
                rects.append(CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1))
            }
        }
        return rects
    }()

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

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
                var v = min(maxLevel, max(0, Int(bands[x])))

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
                let cap = (peaksEnabled && level >= 0 && level <= maxLevel) ? level : -1
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

    private func color(_ index: Int, fallback: CGColor) -> CGColor {
        colors.indices.contains(index) ? colors[index] : fallback
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let black = CGColor(gray: 0, alpha: 1)
        context.setFillColor(color(0, fallback: black))
        context.fill(bounds)

        context.setFillColor(color(1, fallback: black))
        context.fill(gridRects)

        let floor = bounds.height - 1

        // Every lit pixel in a row shares a color, so a row is one fill.
        for row in 0..<maxLevel {
            rowRects.removeAll(keepingCapacity: true)
            for x in 0..<Self.columnCount where barLevels[x] > row {
                rowRects.append(CGRect(x: CGFloat(x), y: floor - CGFloat(row), width: 1, height: 1))
            }
            guard !rowRects.isEmpty else { continue }
            context.setFillColor(color(min(17, max(2, 17 - row)), fallback: black))
            context.fill(rowRects)
        }

        peakRects.removeAll(keepingCapacity: true)
        for x in 0..<Self.columnCount where peakLevels[x] >= 0 {
            peakRects.append(CGRect(x: CGFloat(x), y: floor - CGFloat(peakLevels[x]), width: 1, height: 1))
        }
        if !peakRects.isEmpty {
            context.setFillColor(color(23, fallback: CGColor(gray: 1, alpha: 1)))
            context.fill(peakRects)
        }
    }
}

/// Hosts the analyzer in SwiftUI. The view below redraws itself off the display
/// link, so nothing here updates once it is installed except the palette.
struct SpectrumAnalyzerLayer: NSViewRepresentable {
    let colors: [Color]
    let bands: () -> [Float]
    let isRendering: () -> Bool

    func makeNSView(context: Context) -> SpectrumAnalyzerNSView {
        let view = SpectrumAnalyzerNSView()
        view.bandsProvider = bands
        view.isRenderingProvider = isRendering
        view.colors = Self.cgColors(from: colors)
        return view
    }

    func updateNSView(_ nsView: SpectrumAnalyzerNSView, context: Context) {
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
