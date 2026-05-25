import SwiftUI

/// Compact slider used inside the EQ window's shaded titlebar for volume
/// (97×6 area, value range 0…1) and balance (43×6 area, value range −1…+1).
///
/// Webamp parity:
/// - `packages/webamp/js/components/EqualizerWindow/EqualizerShade.tsx` mounts
///   `<Volume id="equalizer-volume" />` and `<Balance id="equalizer-balance" />`
///   with `className = segment(min, max, value, ["left","center","right"])`.
/// - `packages/webamp/css/equalizer-window.css` sets the slider geometry —
///   `#equalizer-volume { left:61 top:4 width:97 height:6 }`,
///   `#equalizer-balance { left:164 top:4 width:43 height:6 }`.
/// - `packages/webamp/js/skinSprites.ts` defines `EQ_SHADE_{VOLUME,BALANCE}_SLIDER_{LEFT,CENTER,RIGHT}`
///   as 3×7 thumb sprites; the track is baked into `EQ_SHADE_BACKGROUND`.
struct EQShadeSlider: View {
    @Binding var value: Float
    /// Inclusive value range — `0...1` for volume, `-1...1` for balance.
    let valueRange: ClosedRange<Float>
    /// Track length in pixels (97 for volume, 43 for balance).
    let trackWidth: CGFloat
    /// Sprite-name prefix; the segment suffix (`_LEFT` / `_CENTER` / `_RIGHT`)
    /// is appended at render time. e.g. `"EQ_SHADE_VOLUME_SLIDER"`.
    let spritePrefix: String
    /// Fires once when the user releases the drag — use to commit gesture-rate
    /// state (UserDefaults persistence, undo coalescing, etc.).
    var onDragEnded: (() -> Void)?

    private let thumbWidth: CGFloat = 3
    private let thumbHeight: CGFloat = 7

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Hit area spans the full track. Placed BELOW the thumb so the
            // thumb sprite renders on top; `allowsHitTesting(false)` on the
            // thumb keeps clicks on the thumb falling through to this layer.
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            updateValue(toLocalX: gesture.location.x)
                        }
                        .onEnded { _ in
                            onDragEnded?()
                        }
                )

            SimpleSpriteImage(
                "\(spritePrefix)_\(thumbSegment)",
                width: thumbWidth,
                height: thumbHeight
            )
            .offset(x: thumbXOffset)
            .allowsHitTesting(false)
        }
        .frame(width: trackWidth, height: thumbHeight, alignment: .topLeading)
    }

    /// Maps the current `value` to one of the three sprite suffixes the same
    /// way Webamp's `segment(min, max, value, ["left","center","right"])` does:
    /// equal-width thirds across `valueRange`.
    private var thumbSegment: String {
        let fraction = normalizedFraction
        if fraction < 1.0 / 3.0 { return "LEFT" }
        if fraction < 2.0 / 3.0 { return "CENTER" }
        return "RIGHT"
    }

    /// Pixel offset of the thumb's left edge along the track. The thumb's
    /// LEFT edge sweeps `[0, trackWidth − thumbWidth]` so the entire thumb
    /// stays within the track.
    private var thumbXOffset: CGFloat {
        let fraction = normalizedFraction
        return CGFloat(fraction) * (trackWidth - thumbWidth)
    }

    private var normalizedFraction: Float {
        let span = valueRange.upperBound - valueRange.lowerBound
        guard span > 0 else { return 0 }
        let f = (value - valueRange.lowerBound) / span
        return max(0, min(1, f))
    }

    private func updateValue(toLocalX x: CGFloat) {
        // The pointer reports its position relative to the gesture's coord
        // space, which here is the ZStack — same width as the track.
        let clampedX = max(0, min(trackWidth, x))
        let fraction = trackWidth > 0 ? Float(clampedX / trackWidth) : 0
        let span = valueRange.upperBound - valueRange.lowerBound
        let newValue = valueRange.lowerBound + fraction * span
        let clamped = max(valueRange.lowerBound, min(valueRange.upperBound, newValue))
        // Skip writes that resolve to the same pixel position — gesture-rate
        // dampening, mirroring `WinampVolumeSlider.updateVolume`.
        let pixelStep = span / Float(trackWidth)
        guard abs(value - clamped) >= pixelStep else { return }
        value = clamped
    }
}
