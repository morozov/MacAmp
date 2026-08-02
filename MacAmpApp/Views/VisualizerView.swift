import SwiftUI

/// Winamp visualizer constants
enum VisualizerLayout {
    static let width: CGFloat = 76
    static let height: CGFloat = 16
    static let oscilloscopeSampleCount = 76
}

/// Winamp-style spectrum analyzer - click to cycle modes
struct VisualizerView: View {
    @Environment(AudioPlayer.self) var audioPlayer
    @Environment(SkinManager.self) var skinManager
    @Environment(AppSettings.self) var settings

    var body: some View {
        let mode = settings.visualizerMode

        // Matches Webamp: visualizer canvas is omitted when stopped, and cleared
        // (transparent) when the active mode is `.none`. In both cases the skin's
        // MAIN.BMP must show through unobstructed (Vis.tsx: returns null on
        // STOPPED, clearRect on NONE).
        //
        // `isPlaying` / `isPaused` are file-playback flags only — HTTP streams
        // route through the engine bridge and leave both at false. Including
        // `isBridgeActive` keeps the visualizer drawing while a stream plays.
        let isStopped = !audioPlayer.isPlaying && !audioPlayer.isPaused && !audioPlayer.isBridgeActive
        let drawsContent = !isStopped && mode != .none

        ZStack {
            // Keep the area hit-testable so tapping cycles modes even when nothing
            // is drawn (stopped, or `.none` mode).
            Color.clear
                .contentShape(Rectangle())

            if drawsContent {
                switch mode {
                case .none:
                    EmptyView()
                case .oscilloscope:
                    VisualizerGridBackground()
                    OscilloscopeView()
                case .spectrum:
                    // Draws its own background, and redraws itself off the
                    // display link without going through SwiftUI state.
                    SpectrumAnalyzerLayer(
                        colors: skinManager.currentSkin?.visualizerColors ?? [],
                        bands: { [audioPlayer] in audioPlayer.spectrumBands() },
                        isRendering: { [audioPlayer] in audioPlayer.isEngineRendering }
                    )
                    .frame(width: VisualizerLayout.width, height: VisualizerLayout.height)
                }
            }
        }
        .frame(width: VisualizerLayout.width, height: VisualizerLayout.height)
        .onTapGesture {
            // Cycle through modes: spectrum → oscilloscope → none
            let allModes = AppSettings.VisualizerMode.allCases
            if let currentIndex = allModes.firstIndex(of: settings.visualizerMode) {
                let nextIndex = (currentIndex + 1) % allModes.count
                settings.visualizerMode = allModes[nextIndex]
            }
        }
    }
}

/// Pre-rendered visualizer background (VISCOLOR color 0 fill + color 1 dot grid).
/// Matches Webamp's `preRenderBg` in `js/components/Vis.tsx`: solid color[0]
/// background, then color[1] 1x1 dots at every (x even, y odd) position.
struct VisualizerGridBackground: View {
    @Environment(SkinManager.self) var skinManager

    var body: some View {
        Canvas { context, size in
            let colors = skinManager.currentSkin?.visualizerColors ?? []
            let bgColor = colors.indices.contains(0) ? colors[0] : Color.black
            let fgColor = colors.indices.contains(1) ? colors[1] : bgColor

            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(bgColor)
            )

            let width = Int(size.width)
            let height = Int(size.height)
            for x in stride(from: 0, to: width, by: 2) {
                for y in stride(from: 1, to: height, by: 2) {
                    context.fill(
                        Path(CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)),
                        with: .color(fgColor)
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    VisualizerView()
        .environment(AudioPlayer())
        .environment(SkinManager())
        .environment(AppSettings.instance())
        .frame(width: VisualizerLayout.width, height: VisualizerLayout.height)
        .background(Color.gray)
}

/// Oscilloscope waveform visualization
struct OscilloscopeView: View {
    @Environment(AudioPlayer.self) var audioPlayer
    @Environment(SkinManager.self) var skinManager

    let updateTimer = Timer.publish(every: 1.0/30.0, on: .main, in: .common).autoconnect()
    @State private var waveformData: [Float] = []

    var body: some View {
        Canvas { context, size in
            guard !waveformData.isEmpty else { return }

            var path = Path()
            let centerY = size.height / 2

            for (index, sample) in waveformData.enumerated() {
                let x = CGFloat(index) / CGFloat(waveformData.count) * size.width
                let y = centerY - (CGFloat(sample) * centerY)

                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            let color = oscilloscopeColor()
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
        .frame(width: VisualizerLayout.width, height: VisualizerLayout.height)
        .onReceive(updateTimer) { _ in
            if audioPlayer.isEngineRendering {
                waveformData = audioPlayer.getWaveformSamples(count: VisualizerLayout.oscilloscopeSampleCount)
            } else {
                waveformData = []
            }
        }
    }

    private func oscilloscopeColor() -> Color {
        if let colors = skinManager.currentSkin?.visualizerColors,
           colors.count >= 19 {
            return colors[18]
        }
        return Color.white
    }
}
