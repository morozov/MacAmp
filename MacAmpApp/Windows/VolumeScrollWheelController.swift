import AppKit

/// Captures scroll-wheel events anywhere over the main and equalizer windows
/// (including when those windows are not key) and translates each notch into
/// a discrete ±3% volume step. Mirrors Webamp's `volume += event.deltaY` in
/// `actionCreators/media.ts#scrollVolume`, where a line-mode wheel reports
/// `deltaY = 3`. Trackpad / smooth scroll is accumulated to a 10-point notch
/// threshold so a single swipe doesn't slam the volume.
@MainActor
final class VolumeScrollWheelController {
    private let registry: WindowRegistry
    private let audioPlayer: AudioPlayer
    private let playbackCoordinator: PlaybackCoordinator
    private var monitor: Any?
    private var trackpadAccumulator: CGFloat = 0

    init(
        registry: WindowRegistry,
        audioPlayer: AudioPlayer,
        playbackCoordinator: PlaybackCoordinator
    ) {
        self.registry = registry
        self.audioPlayer = audioPlayer
        self.playbackCoordinator = playbackCoordinator
        install()
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // `self?.handle(event) ?? event` collapses the optional chain and
            // silently turns a real `nil` (consume) into `event`, letting the
            // scroll-wheel event fall through to whatever lies under the
            // cursor.
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window else { return event }
        guard window === registry.mainWindow || window === registry.eqWindow else { return event }

        let direction = computeDirection(from: event)
        guard direction != 0 else { return nil }

        let currentPct = Int((audioPlayer.volume * 100).rounded())
        let newPct = max(0, min(100, currentPct + direction * 3))
        guard newPct != currentPct else { return nil }

        playbackCoordinator.setVolume(Float(newPct) / 100)
        playbackCoordinator.commitVolume()
        return nil
    }

    private func computeDirection(from event: NSEvent) -> Int {
        let delta = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            return delta > 0 ? 1 : (delta < 0 ? -1 : 0)
        }
        trackpadAccumulator += delta
        let threshold: CGFloat = 10
        if trackpadAccumulator >= threshold {
            trackpadAccumulator -= threshold
            return 1
        }
        if trackpadAccumulator <= -threshold {
            trackpadAccumulator += threshold
            return -1
        }
        return 0
    }
}
