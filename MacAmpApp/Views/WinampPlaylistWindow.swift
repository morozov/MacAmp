import SwiftUI

struct WinampPlaylistWindow: View {
    @Environment(SkinManager.self) private var skinManager
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(AppSettings.self) private var settings
    @Environment(RadioStationLibrary.self) private var radioLibrary
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(WindowFocusState.self) private var windowFocusState

    @State private var ui = PlaylistWindowInteractionState()
    @State private var sizeState = PlaylistWindowSizeState()

    private var windowWidth: CGFloat { sizeState.windowWidth }
    private var windowHeight: CGFloat { sizeState.windowHeight }

    private var isWindowActive: Bool {
        windowFocusState.isPlaylistKey
    }

    /// Pixel ceiling on the scroll offset — i.e. the contentOffset.y value
    /// at which the bottom of the last row aligns with the bottom of the
    /// viewport. Zero when the playlist fits without scrolling.
    private var maxScrollOffsetPixels: CGFloat {
        let totalContentHeight = CGFloat(audioPlayer.playlist.count) * PlaylistWindowSizeState.trackRowHeight
        return max(0, totalContentHeight - sizeState.contentHeight)
    }

    /// Translate an AppKit drop point (in the drop container's flipped
    /// coordinates, y from top) to a playlist insertion index. Webamp's
    /// formula: round to nearest half-row crossing, accounting for the
    /// current scroll offset, then clamp into the valid range.
    private func dropIndex(at point: CGPoint) -> Int {
        let raw = Int(((point.y + ui.scrollOffsetPixels) / PlaylistWindowSizeState.trackRowHeight).rounded())
        return max(0, min(audioPlayer.playlist.count, raw))
    }

    private var playlistStyle: PlaylistStyle {
        skinManager.currentSkin?.playlistStyle ?? .winampDefault
    }

    private var menuPresenter: PlaylistMenuPresenter {
        PlaylistMenuPresenter(
            skinManager: skinManager,
            audioPlayer: audioPlayer,
            windowHeight: windowHeight,
            windowWidth: windowWidth,
            selectedIndices: ui.selectedIndices
        )
    }

    var body: some View {
        GeometryReader { _ in
            ZStack {
                if !ui.isShadeMode {
                    buildCompleteBackground()
                    buildContentOverlay()
                } else {
                    PlaylistShadeView(
                        windowWidth: windowWidth,
                        isWindowActive: isWindowActive,
                        onShadeToggle: { ui.isShadeMode.toggle() },
                        onClose: { WindowCoordinator.shared?.hidePlaylistWindow() }
                    )
                }
            }
            .frame(width: windowWidth, height: ui.isShadeMode ? 14 : windowHeight)
        }
        .frame(width: windowWidth, height: ui.isShadeMode ? 14 : windowHeight)
        .background(Color.black)
        .onAppear {
            ui.installKeyboardMonitor(
                playlistWindow: { WindowCoordinator.shared?.playlistWindow },
                playlistCount: { audioPlayer.playlist.count },
                visibleTrackCount: { sizeState.visibleTrackCount },
                removeTrack: { audioPlayer.removeTrack(at: $0) },
                playTrackAt: { index in
                    guard audioPlayer.playlist.indices.contains(index) else { return }
                    let track = audioPlayer.playlist[index]
                    Task { await playbackCoordinator.play(track: track) }
                }
            )
            PlaylistWindowActions.shared.radioLibrary = radioLibrary
            PlaylistWindowActions.shared.playbackCoordinator = playbackCoordinator
            WindowCoordinator.shared?.updatePlaylistWindowSize(to: sizeState.pixelSize)
        }
        .onChange(of: sizeState.size) { _, newSize in
            let pixelSize = newSize.toPixels()
            WindowCoordinator.shared?.updatePlaylistWindowSize(to: pixelSize)
        }
        .onDisappear {
            ui.removeKeyboardMonitor()
        }
    }

    // MARK: - Content Overlay

    @ViewBuilder
    private func buildContentOverlay() -> some View {
        let contentWidth = sizeState.contentWidth
        let contentHeight = sizeState.contentHeight
        let contentCenterX = PlaylistWindowSizeState.leftBorderWidth + (contentWidth / 2)
        let contentCenterY = PlaylistWindowSizeState.topBarHeight + (contentHeight / 2)

        PlaylistDropContainer(
            content: ZStack {
                playlistStyle.backgroundColor

                PlaylistTrackListView(
                    sizeState: sizeState,
                    playlistStyle: playlistStyle,
                    scrollOffsetPixels: $ui.scrollOffsetPixels,
                    onTrackTap: { ui.handleTrackTap(index: $0) },
                    selectedIndices: ui.selectedIndices,
                    dropIndex: ui.dropIndex
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            },
            onEntered: { point in
                ui.dropIndex = dropIndex(at: point)
            },
            onUpdated: { point in
                ui.dropIndex = dropIndex(at: point)
            },
            onEnded: {
                // Fires for accept, reject, cancel, drag-outside — covers
                // every termination so the marker never lingers.
                ui.dropIndex = nil
            },
            onPerform: { point, urls in
                let targetIndex = dropIndex(at: point)
                ui.dropIndex = nil
                Task { @MainActor in
                    let wasEmpty = audioPlayer.playlist.isEmpty
                    let actions = PlaylistWindowActions.shared
                    let coordinator = actions.playbackCoordinator
                    let hint = await actions.handleSelectedURLs(
                        urls,
                        audioPlayer: audioPlayer,
                        at: targetIndex
                    )
                    guard wasEmpty, let coordinator else { return }
                    if let hint, audioPlayer.playlist.indices.contains(hint.absoluteIndex) {
                        coordinator.selectTrack(audioPlayer.playlist[hint.absoluteIndex])
                    } else if let first = audioPlayer.playlist.first {
                        await coordinator.play(track: first)
                    }
                }
                return true
            }
        )
        .frame(width: contentWidth, height: contentHeight)
        .position(x: contentCenterX, y: contentCenterY)
        .clipped()

        PlaylistBottomControlsView(
            windowWidth: windowWidth,
            windowHeight: windowHeight,
            menuPresenter: menuPresenter
        )

        PlaylistTitleBarButtons(
            windowWidth: windowWidth,
            onShadeToggle: { ui.isShadeMode.toggle() },
            onClose: { WindowCoordinator.shared?.hidePlaylistWindow() }
        )

        PlaylistScrollSlider(
            scrollOffsetPixels: $ui.scrollOffsetPixels,
            maxScrollOffsetPixels: maxScrollOffsetPixels
        )
        .frame(height: sizeState.contentHeight - 4)
        // Webamp's `PlaylistScrollBar` sits inside `.playlist-middle-right`
        // (20px wide) with `marginLeft: 5; width: 8`, so the thumb occupies
        // tile-local x = 5..13 — center at tile-local 9. In window coords:
        // (windowWidth - 20) + 9 = windowWidth - 11. Skin-agnostic per
        // Webamp's CSS, not derived from any particular sprite.
        .position(x: windowWidth - 11, y: PlaylistWindowSizeState.topBarHeight + (sizeState.contentHeight / 2))
        .onChange(of: audioPlayer.playlist.count) { _, _ in
            ui.clampScrollOffset(maxOffsetPixels: maxScrollOffsetPixels)
        }
        .onChange(of: sizeState.contentHeight) { _, _ in
            ui.clampScrollOffset(maxOffsetPixels: maxScrollOffsetPixels)
        }

        PlaylistResizeHandle(
            windowWidth: windowWidth,
            windowHeight: windowHeight,
            sizeState: sizeState,
            dragStartSize: $ui.dragStartSize,
            isDragging: $ui.isDragging,
            resizePreview: ui.resizePreview
        )
    }

    // MARK: - Background Chrome

    @ViewBuilder
    private func buildCompleteBackground() -> some View {
        let suffix = isWindowActive ? "_SELECTED" : ""

        // === TOP BAR ===
        SimpleSpriteImage("PLAYLIST_TOP_LEFT\(isWindowActive ? "_SELECTED" : "_CORNER")", width: 25, height: 20)
            .position(x: 12.5, y: 10)

        ForEach(0..<sizeState.topBarTileCount, id: \.self) { i in
            SimpleSpriteImage("PLAYLIST_TOP_TILE\(suffix)", width: 25, height: 20)
                .position(x: 25 + 12.5 + CGFloat(i) * 25, y: 10)
        }

        WinampTitlebarDragHandle(windowKind: .playlist, size: CGSize(width: 100, height: 20)) {
            SimpleSpriteImage("PLAYLIST_TITLE_BAR\(suffix)", width: 100, height: 20)
        }
        .position(x: windowWidth / 2, y: 10)

        SimpleSpriteImage("PLAYLIST_TOP_RIGHT_CORNER\(suffix)", width: 25, height: 20)
            .position(x: windowWidth - 12.5, y: 10)

        // === SIDE BORDERS ===
        let borderTileCount = sizeState.verticalBorderTileCount
        ForEach(0..<borderTileCount, id: \.self) { i in
            SimpleSpriteImage("PLAYLIST_LEFT_TILE", width: 12, height: 29)
                .position(x: 6, y: 20 + 14.5 + CGFloat(i) * 29)
        }

        ForEach(0..<borderTileCount, id: \.self) { i in
            SimpleSpriteImage("PLAYLIST_RIGHT_TILE", width: 20, height: 29)
                .position(x: windowWidth - 10, y: 20 + 14.5 + CGFloat(i) * 29)
        }

        // === BOTTOM BAR ===
        let showVisualizer = sizeState.size.width >= 3

        SimpleSpriteImage("PLAYLIST_BOTTOM_LEFT_CORNER", width: 125, height: 38)
            .position(x: 62.5, y: windowHeight - 19)

        let centerEndX: CGFloat = showVisualizer ? (windowWidth - 225) : (windowWidth - 150)
        let centerAvailableWidth = max(0, centerEndX - 125)
        let centerTileCount = Int(centerAvailableWidth / 25)

        if centerTileCount > 0 {
            ForEach(0..<centerTileCount, id: \.self) { i in
                SimpleSpriteImage("PLAYLIST_BOTTOM_TILE", width: 25, height: 38)
                    .position(x: 125 + 12.5 + CGFloat(i) * 25, y: windowHeight - 19)
            }
        }

        if showVisualizer {
            SimpleSpriteImage("PLAYLIST_VISUALIZER_BACKGROUND", width: 75, height: 38)
                .position(x: windowWidth - 187.5, y: windowHeight - 19)

            if settings.isMainWindowShaded {
                // Render at 76px native width, clip to 72px to match Winamp's visualizer inset
                VisualizerView()
                    .frame(width: 76, height: 16)
                    .frame(width: 72, alignment: .leading)
                    .clipped()
                    .position(x: windowWidth - 187, y: windowHeight - 18)
            }
        }

        SimpleSpriteImage("PLAYLIST_BOTTOM_RIGHT_CORNER", width: 150, height: 38)
            .position(x: windowWidth - 75, y: windowHeight - 19)
    }
}

extension SimpleSpriteImage {
    func position(x: CGFloat, y: CGFloat) -> some View {
        self.position(CGPoint(x: x, y: y))
    }
}

#Preview {
    WinampPlaylistWindow()
        .environment(SkinManager())
        .environment(AudioPlayer())
        .environment(AppSettings.instance())
}
