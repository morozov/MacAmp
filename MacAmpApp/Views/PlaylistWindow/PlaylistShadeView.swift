import SwiftUI

/// Shaded (14 px) playlist titlebar.
///
/// Webamp parity — `packages/webamp/js/components/PlaylistWindow/PlaylistShade.tsx`:
/// - `name = Selectors.getMinimalMediaText` → `${trackNumber}. ${displayName}`
///   (`packages/webamp/js/selectors.ts` 420-424); `"[No file]"` when no current
///   track (PlaylistShade.tsx 31-33).
/// - `time = name == null ? "" : getTimeStr(duration)` — current track's total
///   duration (NOT elapsed time), suppressed when there's no track.
/// - Trimming per PlaylistShade.tsx 35-43 + `constants.ts`:
///   `MIN_NAME_WIDTH = 205`, `CHARACTER_WIDTH = 5`,
///   `addedWidth = playlistSize[0] * WINDOW_RESIZE_SEGMENT_WIDTH(25)`.
///   `nameLength = (205 + addedWidth) / 5`; slice + UTF8_ELLIPSIS when over.
/// - Layout — `packages/webamp/css/playlist-window.css` 296-307 specifies
///   `#playlist-shade-track-title { top:4 left:5 }` and
///   `#playlist-shade-time { top:4 right:30 }`. MacAmp uses `left: 9` for the
///   title and `right: 29` for the time — these were tuned by visual
///   comparison against a classic-Winamp reference until the title and
///   duration aligned with the original; Webamp's CSS values render the
///   title noticeably tucked into the LEFT cap's dark stripe and the time
///   one pixel further from the right buttons. Documented as a deliberate
///   Webamp deviation.
///
/// Background composition matches Webamp's three-piece layout
/// (`js/components/PlaylistWindow/PlaylistShade.tsx` DOM + `js/skinSprites.ts`
/// 237-258): `PLAYLIST_SHADE_BACKGROUND_LEFT` (25×14) on the left edge,
/// `PLAYLIST_SHADE_BACKGROUND` (25×14) tiled across the middle, and
/// `PLAYLIST_SHADE_BACKGROUND_RIGHT[_SELECTED]` (50×14) on the right edge.
/// Per `js/skinSelectors.ts` 92-97 only the right cap has a focused variant —
/// the left and center are focus-invariant.
struct PlaylistShadeView: View {
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(SkinManager.self) private var skinManager

    let windowWidth: CGFloat
    let isWindowActive: Bool
    let onShadeToggle: () -> Void
    let onClose: () -> Void

    /// Webamp constants (`packages/webamp/js/constants.ts`).
    private static let minNameWidth: CGFloat = 205
    private static let characterWidth: CGFloat = 5
    private static let baseWindowWidth: CGFloat = 275
    private static let ellipsis = "\u{2026}"

    /// Title text including 1-based playlist position prefix. `nil` when no
    /// current track — caller renders nothing and clears the time. Matches
    /// `getMinimalMediaText` (returns `null` when no track is loaded).
    private var minimalMediaText: String? {
        guard let current = playbackCoordinator.currentTrack else { return nil }
        let displayName: String
        if current.artist.isEmpty || current.artist == "Unknown Artist" {
            displayName = current.title
        } else {
            displayName = "\(current.artist) - \(current.title)"
        }
        let index = audioPlayer.playlist.firstIndex { $0.id == current.id } ?? 0
        return "\(index + 1). \(displayName)"
    }

    private var trimmedTrackText: String {
        guard let raw = minimalMediaText else { return "[No file]" }
        let addedWidth = max(0, windowWidth - Self.baseWindowWidth)
        let nameLength = Int((Self.minNameWidth + addedWidth) / Self.characterWidth)
        guard raw.count > nameLength, nameLength > 0 else { return raw }
        let endIndex = raw.index(raw.startIndex, offsetBy: nameLength - 1)
        return String(raw[..<endIndex]) + Self.ellipsis
    }

    private var timeText: String {
        guard let track = playbackCoordinator.currentTrack, track.duration > 0 else { return "" }
        return TimeFormatting.formatDuration(track.duration)
    }

    private var textColor: Color {
        skinManager.currentSkin?.playlistStyle.normalTextColor ?? Color(red: 0, green: 1, blue: 0)
    }

    var body: some View {
        // Drag-capture area sits below the close/shade buttons (rightmost ~24
        // px) and above the visual layers (sprites + text don't capture
        // events). Without it the folded playlist can't be dragged — the
        // full-mode `WinampTitlebarDragHandle` lives in
        // `WinampPlaylistWindow.buildContentOverlay`, which is replaced by
        // this view when shaded.
        let buttonsWidth: CGFloat = 24
        let dragWidth = max(0, windowWidth - buttonsWidth)

        ZStack(alignment: .topLeading) {
            buildShadeBackground()

            PlaylistBitmapText(trimmedTrackText, fallbackColor: textColor, spacing: 0, fallbackSize: 8)
                .at(x: 9, y: 4)

            // Time anchors so its right edge lands at `windowWidth - 29`.
            // PlaylistTimeText lays out left-to-right, so position by the
            // expected pixel width — `text.count * CHARACTER_WIDTH` — anchored
            // so its RIGHT edge lands at the target.
            if !timeText.isEmpty {
                let approxTimeWidth = CGFloat(timeText.count) * Self.characterWidth
                PlaylistTimeText(timeText, spacing: 0)
                    .at(x: windowWidth - 29 - approxTimeWidth, y: 4)
            }

            TitlebarDragCaptureView(windowKind: .playlist)
                .frame(width: dragWidth, height: 14)
                .at(x: 0, y: 0)

            PlaylistTitleBarButtons(
                windowWidth: windowWidth,
                onShadeToggle: onShadeToggle,
                onClose: onClose
            )
        }
        .frame(width: windowWidth, height: 14, alignment: .topLeading)
    }

    /// LEFT cap (25×14) + repeating CENTER (25×14) + RIGHT cap (50×14, focused
    /// variant when active). The center tile count is ceil-divided so the last
    /// tile may extend slightly past the cap-start; that's fine because the
    /// RIGHT cap is drawn on top.
    @ViewBuilder
    private func buildShadeBackground() -> some View {
        let leftCap: CGFloat = 25
        let rightCap: CGFloat = 50
        let centerWidth = max(0, windowWidth - leftCap - rightCap)
        let centerTileCount = Int(ceil(centerWidth / leftCap))
        let rightSprite = isWindowActive ? "PLAYLIST_SHADE_BACKGROUND_RIGHT_SELECTED" : "PLAYLIST_SHADE_BACKGROUND_RIGHT"

        SimpleSpriteImage("PLAYLIST_SHADE_BACKGROUND_LEFT", width: 25, height: 14)
            .at(x: 0, y: 0)

        ForEach(0..<centerTileCount, id: \.self) { i in
            SimpleSpriteImage("PLAYLIST_SHADE_BACKGROUND", width: 25, height: 14)
                .at(x: leftCap + CGFloat(i) * 25, y: 0)
        }

        SimpleSpriteImage(rightSprite, width: 50, height: 14)
            .at(x: windowWidth - rightCap, y: 0)
    }
}
