import SwiftUI

struct PlaylistTrackListView: View {
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator

    let sizeState: PlaylistWindowSizeState
    let playlistStyle: PlaylistStyle
    @Binding var scrollOffset: Int
    let onTrackTap: (Int) -> Void
    let selectedIndices: Set<Int>

    var body: some View {
        let trackWidth = sizeState.contentWidth
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(Array(audioPlayer.playlist.enumerated()), id: \.element.id) { index, track in
                    trackRow(track: track, index: index)
                        .frame(width: trackWidth, height: 13)
                        .background(trackBackground(track: track, index: index))
                        .id(index)
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
            .scrollTargetLayout()
        }
        .scrollPosition(id: scrolledRowBinding, anchor: .top)
    }

    /// Two-way bridge between the ScrollView's first-visible-row id and the
    /// `scrollOffset` Int the rest of the playlist UI (slider, keyboard nav)
    /// reads and writes. Without this, mouse-wheel / trackpad scrolling moves
    /// content without updating `scrollOffset`, so the gold thumb in
    /// `PlaylistScrollSlider` stays pinned.
    private var scrolledRowBinding: Binding<Int?> {
        Binding(
            get: { scrollOffset },
            set: { newValue in
                guard let newValue, newValue != scrollOffset else { return }
                scrollOffset = newValue
            }
        )
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
