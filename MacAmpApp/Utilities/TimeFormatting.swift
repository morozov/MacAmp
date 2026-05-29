import Foundation

/// Shared time formatting for duration displays across playlist and track info views.
enum TimeFormatting {
    /// Format a duration in seconds as "M:SS" under one hour, "H:MM:SS" at or
    /// above — matches classic Winamp's playlist running-time display.
    static func formatDuration(_ seconds: Double) -> String {
        var remaining = max(0, Int(seconds))
        var parts: [Int] = []
        for _ in 0..<2 {
            parts.append(remaining % 60)
            remaining /= 60
        }
        if remaining > 0 { parts.append(remaining) }
        return parts.reversed().enumerated()
            .map { idx, val in String(format: idx == 0 ? "%d" : "%02d", val) }
            .joined(separator: ":")
    }
}
