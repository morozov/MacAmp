import Foundation

/// Gates the deterministic launch mode used by `MacAmpUITests`. Active only
/// when the process is started with `MACAMP_UITEST=1` in its environment, so
/// normal launches are unaffected.
///
/// In this mode the app:
/// - skips restoring the persisted playlist, so it starts empty with no media
///   and no playback;
/// - reads and writes settings/window-frame state through a dedicated
///   `UserDefaults` suite (`defaults`), wiped on launch, so tests neither read
///   nor mutate the user's real preferences and start from a known state;
/// - keeps its persisted playlist in a separate application-support
///   subdirectory (`appSupportDirectoryName`), never the user's `playlist.m3u`.
///
/// Isolation covers the persistence surfaces a keyboard-chord test can reach:
/// `AppSettings`, `WindowFrameStore`, and `PlaylistStateStore`. Other defaults
/// (audio, equalizer, radio) still target the standard suite; route them
/// through `defaults` too when a test starts exercising them.
enum UITestSupport {
    static let isActive = ProcessInfo.processInfo.environment["MACAMP_UITEST"] == "1"

    /// Suite name for the isolated UI-test defaults.
    private static let suiteName = "com.hankyeomans.MacAmp.uitest"

    /// UserDefaults the app reads/writes. The isolated suite is wiped on first
    /// access so each run starts clean; the standard suite is returned in
    /// normal operation. `UserDefaults` is thread-safe, hence `nonisolated`.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard isActive, let suite = UserDefaults(suiteName: suiteName) else { return .standard }
        suite.removePersistentDomain(forName: suiteName)
        return suite
    }()

    /// Application-support subdirectory for persisted files. A distinct folder
    /// in UI-test mode keeps the test playlist out of the user's real one.
    static var appSupportDirectoryName: String { isActive ? "MacAmp-UITest" : "MacAmp" }

    /// Number of placeholder tracks to seed into the playlist at launch, for
    /// tests that need a populated list (crop, clear). Zero unless the test
    /// sets `MACAMP_UITEST_SEED_PLAYLIST`.
    static var seedPlaylistCount: Int {
        guard isActive else { return 0 }
        return Int(ProcessInfo.processInfo.environment["MACAMP_UITEST_SEED_PLAYLIST"] ?? "") ?? 0
    }
}
