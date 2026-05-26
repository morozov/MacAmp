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
/// - Layout — `packages/webamp/css/playlist-window.css` 296-307:
///   `#playlist-shade-track-title { top:4 left:5 }`,
///   `#playlist-shade-time { top:4 right:30 }`.
///
/// Background sprite fidelity: Webamp uses
/// `PLAYLIST_SHADE_BACKGROUND_LEFT (25×14)` + repeating
/// `PLAYLIST_SHADE_BACKGROUND (25×14)` + `PLAYLIST_SHADE_BACKGROUND_RIGHT (50×14)`
/// caps (`js/skinSprites.ts` 237-258). MacAmp doesn't yet define those rects in
/// `SkinSprites.swift`, so this view still uses the stretched full-mode
/// `PLAYLIST_TITLE_BAR` sprite — to be replaced in a follow-up.
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
        ZStack(alignment: .topLeading) {
            let suffix = isWindowActive ? "_SELECTED" : ""
            SimpleSpriteImage("PLAYLIST_TITLE_BAR\(suffix)", width: 275, height: 14)
                .frame(width: windowWidth, height: 14)

            PlaylistBitmapText(trimmedTrackText, fallbackColor: textColor, spacing: 0, fallbackSize: 8)
                .at(x: 5, y: 4)

            // Time anchors to right edge minus 30 px (Webamp CSS `right: 30`).
            // PlaylistTimeText lays out left-to-right, so position by the
            // expected pixel width — `text.count * (CHARACTER_WIDTH + spacing)`
            // — anchored so its RIGHT edge lands at `windowWidth - 30`.
            if !timeText.isEmpty {
                let approxTimeWidth = CGFloat(timeText.count) * Self.characterWidth
                PlaylistTimeText(timeText, spacing: 0)
                    .at(x: windowWidth - 30 - approxTimeWidth, y: 4)
            }

            PlaylistTitleBarButtons(
                windowWidth: windowWidth,
                onShadeToggle: onShadeToggle,
                onClose: onClose
            )
        }
        .frame(width: windowWidth, height: 14, alignment: .topLeading)
    }
}
