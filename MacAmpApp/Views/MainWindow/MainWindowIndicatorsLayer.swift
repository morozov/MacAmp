import SwiftUI

/// Play/pause indicator, mono/stereo, bitrate, and sample rate displays.
/// Only re-evaluates when playback state or audio metadata changes.
struct MainWindowIndicatorsLayer: View {
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(AudioPlayer.self) private var audioPlayer
    let pauseBlinkVisible: Bool

    private typealias Layout = WinampMainWindowLayout

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
        // Streams report bits/second; files report kbps already. Normalize
        // to kbps for display by dividing if the value is large enough to
        // be in bits/second (>= 1000).
        let raw = playbackCoordinator.currentBitrate
        let kbps = raw >= 1000 ? raw / 1000 : raw
        if kbps > 0 {
            let bitrateText = "\(kbps)"
            HStack(spacing: 0) {
                ForEach(Array(bitrateText.enumerated()), id: \.offset) { _, character in
                    if let ascii = character.asciiValue {
                        SimpleSpriteImage("CHARACTER_\(ascii)", width: 5, height: 6)
                    }
                }
            }
            .at(x: 111, y: 43)
        }
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
