import SwiftUI

struct PlaylistBottomControlsView: View {
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(UserActionDispatcher.self) private var dispatcher

    let windowWidth: CGFloat
    let windowHeight: CGFloat
    let menuPresenter: PlaylistMenuPresenter
    let selectedIndices: Set<Int>

    private var totalPlaylistDuration: Double {
        audioPlayer.playlist.reduce(0.0) { total, track in
            total + track.duration
        }
    }

    private var selectedTracksDuration: Double {
        audioPlayer.playlist.enumerated().reduce(0.0) { sum, pair in
            selectedIndices.contains(pair.offset) ? sum + pair.element.duration : sum
        }
    }

    private var remainingTime: Double {
        guard audioPlayer.currentDuration > 0 else { return 0 }
        return max(0, audioPlayer.currentDuration - audioPlayer.currentTime)
    }

    private var trackTimeText: String {
        // Per Webamp `selectors.ts` getRunningTimeMessage and Winamp
        // Src/Winamp/draw_pe.cpp lines 752-790 (the seltime / ttime branch),
        // this field is selectedTracksSum/totalTracksSum — independent of
        // playback. Left half collapses to "0:00" with nothing selected.
        let selected = TimeFormatting.formatDuration(selectedTracksDuration)
        let total = TimeFormatting.formatDuration(totalPlaylistDuration)
        return "\(selected)/\(total)"
    }

    private var remainingMinutes: Int { max(0, Int(remainingTime)) / 60 }

    /// Hundred-minutes digit, present only at or above 100 minutes so the slot
    /// stays blank below that. Wraps modulo 10, rolling over at 1000 minutes.
    private var miniTimeHundreds: String? {
        remainingMinutes >= 100 ? String((remainingMinutes / 100) % 10) : nil
    }

    private var miniTimeMinutes: String {
        String(format: "%02d", remainingMinutes % 100)
    }

    private var miniTimeSeconds: String {
        String(format: "%02d", max(0, Int(remainingTime)) % 60)
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
        // Per Src/Winamp/draw_pe.cpp `draw_pe_infostr` (lines 73-103), the
        // running-time field is 18 × 5-px glyphs with no gap, anchored at
        // top-left (config_pe_width-143, config_pe_height-28). Per
        // `draw_pe_timedisp` (lines 562-611), the MiniTime field anchors at
        // (config_pe_width-86, config_pe_height-15) as discrete slots: minus
        // at offset 4 (width 3), minutes at offset 9 (width 10), seconds at
        // offset 22 (width 10). The colon at offset 19-21 is part of the
        // PLAYLIST_BOTTOM_RIGHT_CORNER sprite — leave that gap uncovered.
        // From 100 minutes on, a hundred-minutes digit fills offset 4 (width 5)
        // and the minus shifts left to offset 0 to clear it.
        // SwiftUI .position centers, so add half-frame to land each top-left
        // at Winamp's coordinates.
        let glyphHeight: CGFloat = 6
        let glyphWidth: CGFloat = 5
        let runningWidth = glyphWidth * 18
        let runningLeft = windowWidth - 143
        let runningTop = windowHeight - 28
        let miniLeft = windowWidth - 86
        let miniTop = windowHeight - 15
        let miniMidY = miniTop + glyphHeight / 2

        PlaylistTimeText(trackTimeText, spacing: 0)
            .frame(width: runningWidth, height: glyphHeight, alignment: .leading)
            .position(x: runningLeft + runningWidth / 2,
                      y: runningTop + glyphHeight / 2)

        if audioPlayer.isPlaying {
            PlaylistTimeText("-", spacing: 0)
                .frame(width: 3, height: glyphHeight, alignment: .leading)
                .position(x: miniLeft + (miniTimeHundreds != nil ? 0 : 4) + 1.5, y: miniMidY)
        }

        if let hundreds = miniTimeHundreds {
            PlaylistTimeText(hundreds, spacing: 0)
                .frame(width: 5, height: glyphHeight, alignment: .leading)
                .position(x: miniLeft + 4 + 2.5, y: miniMidY)
        }

        PlaylistTimeText(miniTimeMinutes, spacing: 0)
            .frame(width: 10, height: glyphHeight, alignment: .leading)
            .position(x: miniLeft + 9 + 5, y: miniMidY)

        PlaylistTimeText(miniTimeSeconds, spacing: 0)
            .frame(width: 10, height: glyphHeight, alignment: .leading)
            .position(x: miniLeft + 22 + 5, y: miniMidY)
    }
}
