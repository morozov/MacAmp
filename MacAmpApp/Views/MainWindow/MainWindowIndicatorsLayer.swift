import SwiftUI

/// Play/pause indicator, mono/stereo, bitrate, and sample rate displays.
/// Only re-evaluates when playback state or audio metadata changes.
struct MainWindowIndicatorsLayer: View {
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(AudioPlayer.self) private var audioPlayer
    let pauseBlinkVisible: Bool

    private typealias Layout = WinampMainWindowLayout

    /// Interval between bitrate-display refreshes. Each tick re-lays out the
    /// whole hosted main window, and the digit-by-digit numeric readout reads
    /// as noise when it ticks faster than once a second, so a faster rate is
    /// pure wasted CPU.
    private static let bitrateRefreshInterval: TimeInterval = 1.0

    var body: some View {
        // Play/Pause indicator
        buildPlayPauseIndicator()

        // Mono/Stereo indicator
        buildMonoStereoIndicator()

        // Bitrate display
        buildBitrateDisplay()

        // Sample rate display
        buildSampleRateDisplay()
    }

    private func buildPlayPauseIndicator() -> some View {
        let spriteKey: String
        if playbackCoordinator.isPlaying {
            spriteKey = "MAIN_PLAYING_INDICATOR"
        } else if playbackCoordinator.isPaused {
            spriteKey = "MAIN_PAUSED_INDICATOR"
        } else {
            spriteKey = "MAIN_STOPPED_INDICATOR"
        }

        return SimpleSpriteImage(spriteKey, width: 9, height: 9)
            .at(Layout.playPauseIndicator)
    }

    @ViewBuilder
    private func buildMonoStereoIndicator() -> some View {
        // Read from PlaybackCoordinator so the indicators work for both
        // local files and streams without each call site repeating the
        // file-vs-stream branch.
        let channels = playbackCoordinator.currentChannelCount
        ZStack {
            SimpleSpriteImage(channels == 1 ? "MAIN_MONO_SELECTED" : "MAIN_MONO",
                            width: 27, height: 12)
                .at(x: 212, y: 41)
            SimpleSpriteImage(channels == 2 ? "MAIN_STEREO_SELECTED" : "MAIN_STEREO",
                            width: 29, height: 12)
                .at(x: 239, y: 41)
        }
    }

    @ViewBuilder
    private func buildBitrateDisplay() -> some View {
        // `PlaybackCoordinator.currentBitrate` is a computed query into a
        // non-`@Observable` `BitrateTracker`, so SwiftUI's observation
        // tracking doesn't see it change. `TimelineView` schedules a
        // periodic re-evaluation that survives parent re-renders (unlike
        // a `let` `Timer.publish(...)` on the View struct, which gets
        // re-initialized on each render and can lose its tick at slower
        // intervals). Both sources report bits/second.
        //
        // Gated on play/pause so an idle app doesn't schedule 10 Hz
        // wake-ups for a closure that would render nothing.
        if playbackCoordinator.isPlaying || playbackCoordinator.isPaused {
            TimelineView(.periodic(from: .now, by: Self.bitrateRefreshInterval)) { _ in
                let kbps = playbackCoordinator.currentBitrate / 1000
                if kbps > 0 {
                    let cells = BitrateFormatting.mainWindowCells(kbps: kbps)
                    HStack(spacing: 0) {
                        ForEach(Array(cells.enumerated()), id: \.offset) { _, character in
                            SimpleSpriteImage("CHARACTER_\(Self.glyphCode(for: character))", width: 5, height: 6)
                        }
                    }
                    .at(x: 111, y: 43)
                }
            }
        }
    }

    /// Map a readout character to its `CHARACTER_<code>` sprite suffix. The
    /// small font sheet only carries lowercase letters, so the `H`/`C` bitrate
    /// suffixes fold to their lowercase code points, matching how
    /// `MainWindowTrackInfoLayer` renders uppercase text.
    private static func glyphCode(for character: Character) -> UInt8 {
        guard let ascii = character.asciiValue else { return 32 }
        return character.isLetter && character.isUppercase ? ascii + 32 : ascii
    }

    @ViewBuilder
    private func buildSampleRateDisplay() -> some View {
        let sampleRate = playbackCoordinator.currentSampleRate
        if sampleRate > 0 {
            let sampleRateText = "\(sampleRate / 1000)"
            HStack(spacing: 0) {
                ForEach(Array(sampleRateText.enumerated()), id: \.offset) { _, character in
                    if let ascii = character.asciiValue {
                        SimpleSpriteImage("CHARACTER_\(ascii)", width: 5, height: 6)
                    }
                }
            }
            .at(x: 156, y: 43)
        }
    }
}
