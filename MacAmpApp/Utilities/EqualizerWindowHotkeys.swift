import Foundation

/// Bare-key bindings that fire only while the equalizer window is the key
/// window: `N` toggles the EQ on/off, `A` toggles auto-preset. A pure lookup so
/// the mapping is unit-testable without AppKit; the equalizer window installs a
/// key monitor that consults it.
enum EqualizerWindowHotkeys {
    /// The action for a bare key, or nil if the key has no equalizer binding.
    static func action(forKey key: String) -> UserAction? {
        switch key.lowercased() {
        case "n": return .toggleEqualizerEnabled
        case "a": return .toggleEqualizerAuto
        default: return nil
        }
    }
}
