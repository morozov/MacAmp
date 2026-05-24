import Foundation

// MARK: - CueSlice

/// A logical track defined by a CUE sheet entry. A CUE-derived `Track` carries
/// a `cueSlice` describing the slice's position within the underlying audio
/// file: `startTime` is the absolute offset in the file, `duration` is the
/// gap to the next slice's start (or to EOF for the last slice).
struct CueSlice: Equatable, Sendable {
    let startTime: Double
    let duration: Double
    let cueSheetURL: URL

    /// Absolute end time within the underlying audio file.
    var endTime: Double { startTime + duration }
}

// MARK: - Track

/// Represents a single audio or video track in the playlist.
/// Provides metadata and identifies stream vs local file playback routing.
struct Track: Identifiable, Equatable, Sendable {
    let id = UUID()
    let url: URL
    var title: String
    var artist: String
    var duration: Double
    var cueSlice: CueSlice?

    init(
        url: URL,
        title: String,
        artist: String,
        duration: Double,
        cueSlice: CueSlice? = nil
    ) {
        self.url = url
        self.title = title
        self.artist = artist
        self.duration = duration
        self.cueSlice = cueSlice
    }

    /// Returns true if this track is an internet radio stream (HTTP/HTTPS URL)
    /// Streams cannot be played via AudioPlayer (which uses AVAudioFile for local files only)
    /// and must be routed through PlaybackCoordinator → StreamPlayer instead.
    var isStream: Bool {
        let scheme = url.scheme?.lowercased()
        return !url.isFileURL && (scheme == "http" || scheme == "https")
    }

    /// True when this track plays a CUE-defined slice of `url` rather than the whole file.
    var isCueSlice: Bool { cueSlice != nil }

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Playback State

/// Reason why playback stopped
enum PlaybackStopReason: Equatable, Sendable {
    case manual     // User pressed stop
    case completed  // Track finished playing
    case ejected    // Track was removed from playlist
}

/// Current state of the audio/video player
enum PlaybackState: Equatable, Sendable {
    case idle
    case preparing
    case playing
    case paused
    case stopped(PlaybackStopReason)
}
