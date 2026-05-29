import SwiftUI

struct PlaylistTrackListView: View {
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator

    let sizeState: PlaylistWindowSizeState
    let playlistStyle: PlaylistStyle
    @Binding var scrollOffsetPixels: CGFloat
    let onTrackTap: (Int) -> Void
    let selectedIndices: Set<Int>
    let dropIndex: Int?

    @State private var scrollPosition = ScrollPosition()

    var body: some View {
        let trackWidth = sizeState.contentWidth
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(Array(audioPlayer.playlist.enumerated()), id: \.element.id) { index, track in
                    trackRow(track: track, index: index)
                        .frame(width: trackWidth, height: PlaylistWindowSizeState.trackRowHeight)
                        .background(trackBackground(track: track, index: index))
                        .overlay(
                            ClickCatcherView(
                                onSingleClick: { onTrackTap(index) },
                                onDoubleClick: {
                                    Task { await playbackCoordinator.play(track: track) }
                                }
                            )
                        )
                }
            }
        }
        .overlay(alignment: .top) {
            // Webamp shows no drop indicator (DropTarget.tsx relies on the
            // system link cursor alone). This is a deliberate deviation: a
            // 2-pt bar at the insertion point uses the skin's selected-row
            // color so it reads against any palette.
            if let dropIndex {
                let y = CGFloat(dropIndex) * PlaylistWindowSizeState.trackRowHeight
                    - scrollOffsetPixels
                Rectangle()
                    .fill(playlistStyle.selectedBackgroundColor)
                    .frame(width: trackWidth, height: 2)
                    .offset(y: y - 1)
                    .allowsHitTesting(false)
            }
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, newY in
            // User-driven scroll. Tolerance avoids feedback loops from float
            // round-trips when programmatic scrolls land on non-integer offsets.
            if abs(scrollOffsetPixels - newY) > 0.5 {
                scrollOffsetPixels = newY
            }
        }
        .onChange(of: scrollOffsetPixels) { _, newPixels in
            scrollPosition.scrollTo(point: CGPoint(x: 0, y: newPixels))
        }
        .onAppear {
            // Restore the persisted offset when the view first appears.
            if scrollOffsetPixels > 0 {
                scrollPosition.scrollTo(point: CGPoint(x: 0, y: scrollOffsetPixels))
            }
        }
    }

    /// Track-cell font. Webamp wires `${skin.font}, Arial, sans-serif` at
    /// 9 px (`packages/webamp/js/components/PlaylistWindow/TrackCell.tsx` +
    /// `playlist-window.css`), but classic Winamp's playlist preferences
    /// default to Arial 12. Honoring the latter — what the user actually
    /// configures — with skin's pledit.txt Font taking precedence when set.
    private var trackFont: Font {
        if let name = playlistStyle.fontName, !name.isEmpty {
            return .custom(name, size: 12)
        }
        return .custom("Arial", size: 12)
    }

    @ViewBuilder
    private func trackRow(track: Track, index: Int) -> some View {
        let textColor = trackTextColor(track: track)
        // Padding values measured by OCRing the Winamp reference screenshot
        // (image at 1:1 scale, content area 243 px wide):
        //   leading: "1." text left edge at content_x=4
        //   trailing: "M:SS" text right edge at content_x=240 (3 px from edge)
        //   index↔title spacing: ~2 px (Winamp uses intrinsic widths, not a
        //     fixed column, so the title shifts right by ~3-4 px when the
        //     index crosses single→double digits — drop the explicit
        //     `.frame(width:)` on index/duration to match)
        HStack(spacing: 2) {
            Text("\(index + 1).")
                .font(trackFont)
                .foregroundColor(textColor)

            Text("\(track.title) - \(track.artist)")
                .font(trackFont)
                .foregroundColor(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(TimeFormatting.formatDuration(track.duration))
                .font(trackFont)
                .foregroundColor(textColor)
        }
        .padding(.leading, 4)
        .padding(.trailing, 3)
    }

    private func trackTextColor(track: Track) -> Color {
        if let currentTrack = playbackCoordinator.currentTrack,
           currentTrack.url == track.url,
           currentTrack.cueSlice?.startTime == track.cueSlice?.startTime {
            return playlistStyle.currentTextColor
        }
        return playlistStyle.normalTextColor
    }

    private func trackBackground(track: Track, index: Int) -> Color {
        if selectedIndices.contains(index) {
            return playlistStyle.selectedBackgroundColor.opacity(0.6)
        }
        return Color.clear
    }
}
