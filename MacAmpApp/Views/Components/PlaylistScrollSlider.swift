import SwiftUI

/// Winamp-style playlist scroll slider with gold thumb.
///
/// Bridge Contract:
/// - Bridge: WinampPlaylistWindow owns `scrollOffsetPixels: CGFloat` and
///   computes `maxScrollOffsetPixels` from playlist size and viewport height.
/// - Presentation: this component renders the thumb at the right fractional
///   position and writes back continuous pixel offsets on drag, so both
///   mouse-wheel scrolls and slider drags stay smooth (no row-quantization
///   step).
struct PlaylistScrollSlider: View {
    @Binding var scrollOffsetPixels: CGFloat
    let maxScrollOffsetPixels: CGFloat

    @Environment(SkinManager.self) private var skinManager

    private let handleWidth: CGFloat = 8
    private let handleHeight: CGFloat = 18

    @State private var isDragging = false

    // MARK: - Computed Properties

    /// Current scroll position as fraction (0.0 to 1.0).
    private var scrollFraction: CGFloat {
        guard maxScrollOffsetPixels > 0 else { return 0 }
        return min(1, max(0, scrollOffsetPixels / maxScrollOffsetPixels))
    }

    /// Whether the slider is disabled (all content fits, nothing to scroll).
    private var isDisabled: Bool {
        maxScrollOffsetPixels <= 0
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            let availableHeight = geometry.size.height - handleHeight
            let handleOffset = scrollFraction * availableHeight

            ZStack(alignment: .top) {
                // Track (transparent — scroll track is part of PLAYLIST_RIGHT_TILE)
                Color.clear

                // Handle (gold thumb)
                SimpleSpriteImage(
                    isDragging ? "PLAYLIST_SCROLL_HANDLE_SELECTED" : "PLAYLIST_SCROLL_HANDLE",
                    width: handleWidth,
                    height: handleHeight
                )
                .offset(y: handleOffset)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        guard !isDisabled else { return }
                        let clamped = min(1, max(0, value.location.y / geometry.size.height))
                        scrollOffsetPixels = clamped * maxScrollOffsetPixels
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.5 : 1.0)
        }
        .frame(width: handleWidth)
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var scrollOffsetPixels: CGFloat = 0

        var body: some View {
            HStack {
                PlaylistScrollSlider(
                    scrollOffsetPixels: $scrollOffsetPixels,
                    maxScrollOffsetPixels: 500
                )
                .frame(height: 174)
                .background(Color.black.opacity(0.3))

                Text(String(format: "Offset: %.1f", scrollOffsetPixels))
            }
            .padding()
            .environment(SkinManager())
        }
    }

    return PreviewWrapper()
}
