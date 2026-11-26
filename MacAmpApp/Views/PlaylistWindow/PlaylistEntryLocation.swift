import Foundation

enum PlaylistEntryLocation {
    static func url(from text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value)
        }
        if value.hasPrefix("~/") {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "file":
            return url.path.hasPrefix("/") ? url : nil
        case "http", "https":
            return url.host?.isEmpty == false ? url : nil
        default:
            return nil
        }
    }
}
