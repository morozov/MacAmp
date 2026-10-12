import Foundation
import SwiftUI
import Observation

/// Global app settings for MacAmp
@Observable
@MainActor
final class AppSettings {

    // MARK: - UserDefaults Keys

    /// Centralized storage keys to prevent typos and enable refactoring
    private enum Keys {
        static let isDoubleSizeMode = "isDoubleSizeMode"
        static let isAlwaysOnTop = "isAlwaysOnTop"
        static let isMainWindowShaded = "isMainWindowShaded"
        static let showVideoWindow = "showVideoWindow"
        static let showMilkdropWindow = "showMilkdropWindow"
        static let showEqualizerWindow = "showEqualizerWindow"
        static let showPlaylistWindow = "showPlaylistWindow"
        static let isEqualizerWindowShaded = "isEqualizerWindowShaded"
        static let isPlaylistWindowShaded = "isPlaylistWindowShaded"
        static let timeDisplayMode = "timeDisplayMode"
        static let visualizerMode = "visualizerMode"
        static let repeatMode = "repeatMode"
        static let butterchurnRandomize = "butterchurnRandomize"
        static let butterchurnCycling = "butterchurnCycling"
        static let butterchurnCycleInterval = "butterchurnCycleInterval"
        static let butterchurnTrackTitleInterval = "butterchurnTrackTitleInterval"
        // Legacy key for migration
        static let audioPlayerRepeatEnabled = "audioPlayerRepeatEnabled"
    }

    @ObservationIgnored private static let shared = AppSettings()

    private init() {
        // Load persisted clutter bar states (default to false)
        self.isDoubleSizeMode = UITestSupport.defaults.bool(forKey: Keys.isDoubleSizeMode)
        self.isAlwaysOnTop = UITestSupport.defaults.bool(forKey: Keys.isAlwaysOnTop)
        self.isMainWindowShaded = UITestSupport.defaults.bool(forKey: Keys.isMainWindowShaded)
        self.showVideoWindow = UITestSupport.defaults.bool(forKey: Keys.showVideoWindow)
        self.showMilkdropWindow = UITestSupport.defaults.bool(forKey: Keys.showMilkdropWindow)
        self.showEqualizerWindow = UITestSupport.defaults.object(forKey: Keys.showEqualizerWindow) as? Bool ?? true
        self.showPlaylistWindow = UITestSupport.defaults.object(forKey: Keys.showPlaylistWindow) as? Bool ?? true
        self.isEqualizerWindowShaded = UITestSupport.defaults.bool(forKey: Keys.isEqualizerWindowShaded)
        self.isPlaylistWindowShaded = UITestSupport.defaults.bool(forKey: Keys.isPlaylistWindowShaded)

        // NOTE: videoWindowSizeMode loading removed - Size2D persisted in VideoWindowSizeState

        // Load persisted time display mode (default to elapsed)
        if let rawTimeMode = UITestSupport.defaults.string(forKey: Keys.timeDisplayMode),
           let mode = TimeDisplayMode(rawValue: rawTimeMode) {
            self.timeDisplayMode = mode
        } else {
            self.timeDisplayMode = .elapsed
        }

        // Load persisted visualizer mode (default to spectrum)
        let rawMode = UITestSupport.defaults.integer(forKey: Keys.visualizerMode)
        self.visualizerMode = VisualizerMode(rawValue: rawMode) ?? .spectrum

        // Load repeat mode with migration from old boolean (preserves user preference)
        if let savedMode = UITestSupport.defaults.string(forKey: Keys.repeatMode),
           let mode = RepeatMode(rawValue: savedMode) {
            self.repeatMode = mode
        } else {
            // Migrate from old boolean key: true → .all, false → .off
            let oldRepeat = UITestSupport.defaults.bool(forKey: Keys.audioPlayerRepeatEnabled)
            self.repeatMode = oldRepeat ? .all : .off
        }

        // Load Butterchurn settings (with sensible defaults)
        self.butterchurnRandomize = UITestSupport.defaults.object(forKey: Keys.butterchurnRandomize) as? Bool ?? true
        self.butterchurnCycling = UITestSupport.defaults.object(forKey: Keys.butterchurnCycling) as? Bool ?? true
        let savedInterval = UITestSupport.defaults.double(forKey: Keys.butterchurnCycleInterval)
        self.butterchurnCycleInterval = savedInterval > 0 ? savedInterval : 15.0
        self.butterchurnTrackTitleInterval = UITestSupport.defaults.double(forKey: Keys.butterchurnTrackTitleInterval)
    }
    
    static func instance() -> AppSettings {
        return shared
    }

    // MARK: - Skin Settings

    /// Key for storing the selected skin identifier
    private static let selectedSkinKey = "SelectedSkinIdentifier"

    /// The currently selected skin identifier
    var selectedSkinIdentifier: String? {
        get {
            UITestSupport.defaults.string(forKey: Self.selectedSkinKey)
        }
        set {
            UITestSupport.defaults.set(newValue, forKey: Self.selectedSkinKey)
        }
    }

    /// Directory for user-installed skins
    static func userSkinsDirectory(fileManager: FileManager = .default) throws -> URL {
        try ensureSkinsDirectory(fileManager: fileManager)
    }

    @discardableResult
    static func ensureSkinsDirectory(
        fileManager: FileManager = .default,
        base: URL? = nil
    ) throws -> URL {
        let appSupport: URL
        if let base {
            appSupport = base
        } else if UnitTestSupport.isActive, let standIn = UnitTestSupport.applicationSupportDirectory {
            appSupport = standIn
        } else {
            appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        let macampDir = appSupport.appendingPathComponent("MacAmp", isDirectory: true)
        let skinsDir = macampDir.appendingPathComponent("Skins", isDirectory: true)
        try fileManager.createDirectory(at: skinsDir, withIntermediateDirectories: true)
        return skinsDir
    }

    // MARK: - Double Size Mode

    /// Persists across app restarts - defaults to false (100% size)
    /// Note: Using didSet pattern instead of @AppStorage property wrapper
    /// to maintain @Observable reactivity
    var isDoubleSizeMode: Bool = false {
        didSet {
            UITestSupport.defaults.set(isDoubleSizeMode, forKey: Keys.isDoubleSizeMode)
        }
    }

    // MARK: - Always On Top Mode

    /// Persists across app restarts - defaults to false (normal window level)
    /// Note: Using didSet pattern to maintain @Observable reactivity
    var isAlwaysOnTop: Bool = false {
        didSet {
            UITestSupport.defaults.set(isAlwaysOnTop, forKey: Keys.isAlwaysOnTop)
        }
    }

    // MARK: - Main Window Shade Mode

    /// Tracks whether the main window is in shade mode (14px compact bar)
    /// Used by playlist window to show mini visualizer when main visualizer is hidden
    /// Persists across app restarts - defaults to false (full window)
    var isMainWindowShaded: Bool = false {
        didSet {
            UITestSupport.defaults.set(isMainWindowShaded, forKey: Keys.isMainWindowShaded)
        }
    }

    // MARK: - Equalizer / Playlist Window State

    /// EQ window open at quit is reopened at launch (Winamp `eq_open`); defaults to open.
    var showEqualizerWindow: Bool = true {
        didSet { UITestSupport.defaults.set(showEqualizerWindow, forKey: Keys.showEqualizerWindow) }
    }

    /// Playlist window open at quit is reopened at launch (Winamp `pe_open`); defaults to open.
    var showPlaylistWindow: Bool = true {
        didSet { UITestSupport.defaults.set(showPlaylistWindow, forKey: Keys.showPlaylistWindow) }
    }

    var isEqualizerWindowShaded: Bool = false {
        didSet { UITestSupport.defaults.set(isEqualizerWindowShaded, forKey: Keys.isEqualizerWindowShaded) }
    }

    var isPlaylistWindowShaded: Bool = false {
        didSet { UITestSupport.defaults.set(isPlaylistWindowShaded, forKey: Keys.isPlaylistWindowShaded) }
    }

    // MARK: - Time Display Mode

    /// Time display mode for elapsed vs remaining time
    enum TimeDisplayMode: String, Codable, CaseIterable {
        case elapsed
        case remaining
    }

    /// Current time display mode - persists across app restarts
    /// Note: Using didSet pattern to maintain @Observable reactivity
    var timeDisplayMode: TimeDisplayMode = .elapsed {
        didSet {
            UITestSupport.defaults.set(timeDisplayMode.rawValue, forKey: Keys.timeDisplayMode)
        }
    }

    /// Toggle between elapsed and remaining time display
    func toggleTimeDisplayMode() {
        timeDisplayMode = (timeDisplayMode == .elapsed) ? .remaining : .elapsed
    }

    // MARK: - Clutter Bar States

    /// O - Trigger Options Menu via keyboard (transient, not persisted)
    var showOptionsMenuTrigger: Bool = false

    /// I - Track Info Dialog (transient, not persisted)
    var showTrackInfoDialog: Bool = false

    /// The track whose info the dialog shows, resolved when it opens: the
    /// selected playlist item if any, else the playing track. Transient.
    var trackInfoTrack: Track?

    /// File facts for `trackInfoTrack`, loaded before the dialog shows it.
    /// Transient.
    var trackInfoFileInfo: FileInfo?

    // MARK: - Video Window (TASK 2: Day 6)

    /// V - Video Window visibility state (persisted)
    var showVideoWindow: Bool = false {
        didSet {
            UITestSupport.defaults.set(showVideoWindow, forKey: Keys.showVideoWindow)
        }
    }

    // NOTE: videoWindowSizeMode removed - replaced by Size2D in VideoWindowSizeState
    // Video window now uses segment-based resizing ([0,4] = 275×232, [11,12] = 550×464)

    // MARK: - Milkdrop Window (TASK 2: Day 7)

    /// Milkdrop Window visibility state (persisted)
    var showMilkdropWindow: Bool = false {
        didSet {
            UITestSupport.defaults.set(showMilkdropWindow, forKey: Keys.showMilkdropWindow)
        }
    }

    // MARK: - Visualizer Mode

    /// Visualizer display modes
    enum VisualizerMode: Int, Codable, CaseIterable {
        case none = 0
        case spectrum = 1
        case oscilloscope = 2
    }

    /// Current visualizer mode - click analyzer to cycle
    var visualizerMode: VisualizerMode = .spectrum {
        didSet {
            UITestSupport.defaults.set(visualizerMode.rawValue, forKey: Keys.visualizerMode)
        }
    }

    // MARK: - Butterchurn/Milkdrop Settings

    /// Whether to randomize preset selection (default: true, matches Winamp)
    var butterchurnRandomize: Bool = true {
        didSet {
            UITestSupport.defaults.set(butterchurnRandomize, forKey: Keys.butterchurnRandomize)
        }
    }

    /// Whether automatic preset cycling is enabled (default: true)
    var butterchurnCycling: Bool = true {
        didSet {
            UITestSupport.defaults.set(butterchurnCycling, forKey: Keys.butterchurnCycling)
        }
    }

    /// Preset cycle interval in seconds (default: 15s, Milkdrop standard)
    var butterchurnCycleInterval: Double = 15.0 {
        didSet {
            UITestSupport.defaults.set(butterchurnCycleInterval, forKey: Keys.butterchurnCycleInterval)
        }
    }

    /// Track title display interval in seconds (default: 0 = once/manual only)
    /// When > 0, track title is displayed at this interval automatically
    var butterchurnTrackTitleInterval: Double = 0 {
        didSet {
            UITestSupport.defaults.set(butterchurnTrackTitleInterval, forKey: Keys.butterchurnTrackTitleInterval)
        }
    }

    // MARK: - Repeat Mode

    /// Repeat mode matching Winamp 5 Modern behavior
    /// - off: Stop at playlist end
    /// - all: Loop entire playlist (Winamp repeat-all)
    /// - one: Repeat current track (shows "1" badge, Winamp repeat-one)
    enum RepeatMode: String, Codable, CaseIterable {
        case off
        case all

        /// Cycle to the next mode: Off → All → Off.
        func next() -> RepeatMode {
            let cases = Self.allCases
            guard let index = cases.firstIndex(of: self) else { return self }
            let nextIndex = (index + 1) % cases.count
            return cases[nextIndex]
        }

        /// UI display label for tooltips and menus
        var label: String {
            switch self {
            case .off: return "Repeat: Off"
            case .all: return "Repeat: All"
            }
        }

        /// Button state - lit when repeat is on
        var isActive: Bool {
            self != .off
        }
    }

    /// Current repeat mode - persists across app restarts
    /// Note: Using didSet pattern to maintain @Observable reactivity
    var repeatMode: RepeatMode = .off {
        didSet {
            UITestSupport.defaults.set(repeatMode.rawValue, forKey: Keys.repeatMode)
        }
    }
}
