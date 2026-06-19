import SwiftUI

/// Consolidates interaction state previously scattered as @State vars across
/// WinampMainWindow and its extension. Owned by root view, passed to children.
@MainActor
@Observable
final class WinampMainWindowInteractionState {
    // MARK: - Scrubbing (position slider drag)

    var isScrubbing: Bool = false
    var wasPlayingPreScrub: Bool = false
    var scrubbingProgress: Double = 0.0

    // MARK: - Track info scrolling

    var scrollOffset: CGFloat = 0
    var scrollTimer: Timer?

    // MARK: - Marquee transient overrides

    /// When set, pre-empts the playback title in the marquee. Cleared after
    /// `showTransientMessage`'s duration elapses.
    var transientMessage: String?
    private var transientMessageTask: Task<Void, Never>?

    /// Show `text` in the marquee for `duration` seconds, replacing the
    /// playback title. Re-entrant: a new call cancels the prior auto-clear
    /// and restarts the timer.
    func showTransientMessage(_ text: String, duration: TimeInterval = 1.0) {
        transientMessage = text
        transientMessageTask?.cancel()
        transientMessageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.transientMessage = nil
        }
    }

    // MARK: - Pause blinking

    var pauseBlinkVisible: Bool = true
    var isViewVisible: Bool = false

    // MARK: - Scrolling Animation

    /// Closure that returns the current display title. Set by the view layer so the timer
    /// always reads the live value instead of a stale capture.
    var displayTitleProvider: () -> String = { "MacAmp" }

    func startScrolling() {
        guard scrollTimer == nil else { return }
        guard isViewVisible else { return }

        // .common run-loop mode keeps this firing during user gestures (.eventTracking).
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let trackText = self.displayTitleProvider()
                let textWidth = CGFloat(trackText.count * 5)
                let displayWidth = WinampMainWindowLayout.trackInfo.width

                if textWidth > displayWidth {
                    self.scrollOffset -= 5

                    if abs(self.scrollOffset) >= textWidth + 20 {
                        self.scrollOffset = displayWidth
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollTimer = timer
    }

    private var scrollRestartTask: Task<Void, Never>?
    private var scrubResetTask: Task<Void, Never>?

    func resetScrolling() {
        scrollTimer?.invalidate()
        scrollTimer = nil
        scrollOffset = 0
        scrollRestartTask?.cancel()

        scrollRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            guard let self, self.isViewVisible else { return }
            self.startScrolling()
        }
    }

    // MARK: - Position Slider Scrubbing

    func handlePositionDrag(_ value: DragGesture.Value, in geometry: GeometryProxy, audioPlayer: AudioPlayer) {
        scrubResetTask?.cancel()
        if !isScrubbing {
            isScrubbing = true
            wasPlayingPreScrub = audioPlayer.isPlaying
            if wasPlayingPreScrub {
                audioPlayer.pause()
            }
        }

        scrubbingProgress = positionProgress(for: value, in: geometry)
    }

    func handlePositionDragEnd(_ value: DragGesture.Value, in geometry: GeometryProxy, audioPlayer: AudioPlayer) {
        let progress = positionProgress(for: value, in: geometry)

        scrubbingProgress = progress
        audioPlayer.seekToPercent(progress, resume: wasPlayingPreScrub)

        scrubResetTask?.cancel()
        scrubResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            self?.isScrubbing = false
        }
    }

    private func positionProgress(for value: DragGesture.Value, in geometry: GeometryProxy) -> Double {
        let thumbWidth: CGFloat = 29
        let trackableWidth = geometry.size.width - thumbWidth
        guard trackableWidth > 0 else { return 0 }
        let centeredX = value.location.x - thumbWidth / 2
        let clamped = min(max(0, centeredX), trackableWidth)
        return Double(clamped / trackableWidth)
    }

    // MARK: - Time Helpers

    /// Digit values for the MM:SS display, as
    /// `[hundredMinutes, tenMinutes, oneMinutes, tenSeconds, oneSeconds]`.
    ///
    /// The hundred-minutes slot is `-1` below 100 minutes so callers leave it
    /// blank, and becomes visible from 100 minutes on. Every place wraps
    /// modulo 10, so the display rolls over at 1000 minutes rather than
    /// clamping or growing a fourth minute digit.
    func timeDigits(from seconds: Double) -> [Int] {
        let totalSeconds = max(0, Int(seconds))
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60

        return [
            minutes >= 100 ? (minutes / 100) % 10 : -1,
            (minutes / 10) % 10,
            minutes % 10,
            secs / 10,
            secs % 10
        ]
    }

    // MARK: - Lifecycle

    func cleanup() {
        scrollTimer?.invalidate()
        scrollTimer = nil
        scrollRestartTask?.cancel()
        scrollRestartTask = nil
        scrubResetTask?.cancel()
        scrubResetTask = nil
        transientMessageTask?.cancel()
        transientMessageTask = nil
        transientMessage = nil
    }
}
