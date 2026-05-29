import SwiftUI

struct PlaylistBottomControlsView: View {
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(UserActionDispatcher.self) private var dispatcher

    let windowWidth: CGFloat
    let windowHeight: CGFloat
    let menuPresenter: PlaylistMenuPresenter

    private var totalPlaylistDuration: Double {
        audioPlayer.playlist.reduce(0.0) { total, track in
            total + track.duration
        }
    }

    private var remainingTime: Double {
        guard audioPlayer.currentDuration > 0 else { return 0 }
        return max(0, audioPlayer.currentDuration - audioPlayer.currentTime)
    }

    private var trackTimeText: String {
        guard audioPlayer.currentTrack != nil,
              audioPlayer.currentDuration > 0 else {
            return ":"
        }

        let current = TimeFormatting.formatDuration(audioPlayer.currentTime)
        let total = TimeFormatting.formatDuration(totalPlaylistDuration)
        return "\(current) / \(total)"
    }

    private var remainingTimeText: String {
        guard audioPlayer.isPlaying,
              audioPlayer.currentTrack != nil,
              audioPlayer.currentDuration > 0 else {
            return ""
        }

        let remaining = TimeFormatting.formatDuration(remainingTime)
        return "-\(remaining)"
    }

    var body: some View {
        buildMenuButtons()
        buildTransportButtons()
        buildTimeDisplays()
    }

    @ViewBuilder
    private func buildMenuButtons() -> some View {
        // Per Webamp packages/webamp/css/playlist-window.css, each menu container
        // is 22×18 at bottom=12; lefts are 14/43/72/101 and the LIST menu is
        // right=22. SwiftUI .position centers the view, so x = left + 11 and
        // y = windowHeight − 12 − 9.
        let buttonY = windowHeight - 21
        let width: CGFloat = 22
        let height: CGFloat = 18

        Button(action: { menuPresenter.showAddMenu() }, label: {
            Color.clear.frame(width: width, height: height).contentShape(Rectangle())
        }).buttonStyle(.plain).focusable(false).position(x: 25, y: buttonY)

        Button(action: { menuPresenter.showRemMenu() }, label: {
            Color.clear.frame(width: width, height: height).contentShape(Rectangle())
        }).buttonStyle(.plain).focusable(false).position(x: 54, y: buttonY)

        Button(action: { menuPresenter.showSelNotSupportedAlert() }, label: {
            Color.clear.frame(width: width, height: height).contentShape(Rectangle())
        }).buttonStyle(.plain).focusable(false).position(x: 83, y: buttonY)

        Button(action: { menuPresenter.showMiscMenu() }, label: {
            Color.clear.frame(width: width, height: height).contentShape(Rectangle())
        }).buttonStyle(.plain).focusable(false).position(x: 112, y: buttonY)

        Button(action: { menuPresenter.showListMenu() }, label: {
            Color.clear.frame(width: width, height: height).contentShape(Rectangle())
        }).buttonStyle(.plain).focusable(false).position(x: windowWidth - 33, y: buttonY)
    }

    @ViewBuilder
    private func buildTransportButtons() -> some View {
        // Per Webamp packages/webamp/css/playlist-window.css, .playlist-action-buttons
        // is a flex row at top=22, left=3 inside the right-anchored 150-wide
        // .playlist-bottom-right; each child is 10×10 flush. SwiftUI .position
        // centers, so y = windowHeight − 11 (top 22 inside 38-tall bottom + 5) and
        // each x = windowWidth − 147 + N*10 + 5 = windowWidth − 142 + N*10.
        let transportY = windowHeight - 11
        let baseX = windowWidth - 142

        transportButton(action: { dispatcher.perform(.previousTrack) }, x: baseX, y: transportY)
        transportButton(action: { dispatcher.perform(.togglePlayPause) }, x: baseX + 10, y: transportY)
        transportButton(action: { dispatcher.perform(.togglePlayPause) }, x: baseX + 20, y: transportY)
        transportButton(action: { dispatcher.perform(.stop) }, x: baseX + 30, y: transportY)
        transportButton(action: { dispatcher.perform(.nextTrack) }, x: baseX + 40, y: transportY)
        transportButton(action: { dispatcher.perform(.openFiles) }, x: baseX + 50, y: transportY)
    }

    private func transportButton(action: @escaping () -> Void, x: CGFloat, y: CGFloat) -> some View {
        Button(action: action, label: {
            Color.clear.frame(width: 10, height: 10).contentShape(Rectangle())
        })
        .buttonStyle(.plain)
        .focusable(false)
        .position(x: x, y: y)
    }

    @ViewBuilder
    private func buildTimeDisplays() -> some View {
        let rightSectionStart = windowWidth - 150
        let timeY1 = windowHeight - 26
        let timeY2 = windowHeight - 13

        PlaylistTimeText(trackTimeText)
            .position(x: rightSectionStart + 51, y: timeY1)

        if !remainingTimeText.isEmpty {
            PlaylistTimeText(remainingTimeText)
                .position(x: rightSectionStart + 78, y: timeY2)
        }
    }
}
