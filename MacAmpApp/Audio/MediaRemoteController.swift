import MediaPlayer

/// Wires the system `MPRemoteCommandCenter` (Control Center transport,
/// Bluetooth headphone buttons, AirPlay remotes, media keys) into the
/// shared `UserActionDispatcher`. Every remote command translates into a
/// `UserAction` — same dispatch path as a button click or a keyboard
/// shortcut.
///
/// Handlers can fire on arbitrary threads; each one hops to the main
/// actor before calling the dispatcher.
@MainActor
final class MediaRemoteController {
    private let dispatcher: UserActionDispatcher

    init(dispatcher: UserActionDispatcher) {
        self.dispatcher = dispatcher
        installHandlers()
    }

    private func installHandlers() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.dispatcher.perform(.play) }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.dispatcher.perform(.pause) }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.dispatcher.perform(.togglePlayPause) }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.dispatcher.perform(.nextTrack) }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.dispatcher.perform(.previousTrack) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in
                self?.dispatcher.perform(.seekTo(seconds: event.positionTime))
            }
            return .success
        }
    }
}
