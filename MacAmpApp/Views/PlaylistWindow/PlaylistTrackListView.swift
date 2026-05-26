import SwiftUI

struct PlaylistTrackListView: View {
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator

    let sizeState: PlaylistWindowSizeState
    let playlistStyle: PlaylistStyle
    @Binding var scrollOffsetPixels: CGFloat
    let onTrackTap: (Int) -> Void
    let selectedIndices: Set<Int>

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

    @ViewBuilder
    private func trackRow(track: Track, index: Int) -> some View {
        let textColor = trackTextColor(track: track)
        HStack(spacing: 2) {
            Text("\(index + 1).")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(textColor)
                .frame(width: 18, alignment: .trailing)

            Text("\(track.title) - \(track.artist)")
                .font(.system(size: 9))
                .foregroundColor(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            Text(TimeFormatting.formatDuration(track.duration))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(textColor)
                .frame(width: 38, alignment: .trailing)
                .padding(.trailing, 3)
        }
        .padding(.horizontal, 2)
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
