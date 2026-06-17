import Foundation

/// Parser for PLS playlist files (the `[playlist]` / `FileN=` INI format).
///
/// PLS entries are numbered: `File1=`, `Title1=`, `Length1=`, `File2=`, …
/// The parser groups keys by their trailing index and emits one `M3UEntry`
/// per `FileN`, ordered by index, so callers can materialize a PLS through the
/// same path as M3U via `AudioPlayer.addEntries`.
struct PLSParser {
    /// Parse PLS content. Local relative paths resolve against `baseURL`'s
    /// directory; absolute paths and `http(s)` URLs pass through unchanged.
    /// Entries whose `FileN` value is empty or unresolvable are skipped.
    static func parse(content: String, relativeTo baseURL: URL? = nil) -> [M3UEntry] {
        var files: [Int: String] = [:]
        var titles: [Int: String] = [:]
        var lengths: [Int: Int] = [:]

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].lowercased()
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)

            if let index = trailingIndex(of: key, prefix: "file") {
                files[index] = value
            } else if let index = trailingIndex(of: key, prefix: "title") {
                titles[index] = value
            } else if let index = trailingIndex(of: key, prefix: "length") {
                lengths[index] = Int(value)
            }
        }

        var entries: [M3UEntry] = []
        for index in files.keys.sorted() {
            guard let value = files[index], !value.isEmpty,
                  let url = resolve(value, relativeTo: baseURL) else { continue }
            let title = titles[index].flatMap { $0.isEmpty ? nil : $0 }
            // PLS uses -1 for unknown/stream length; treat it as unknown (nil).
            let duration = lengths[index].flatMap { $0 >= 0 ? $0 : nil }
            entries.append(M3UEntry(url: url, title: title, duration: duration))
        }
        return entries
    }

    /// Parse a PLS file from disk; returns an empty array on a read failure.
    static func parse(fileURL: URL) -> [M3UEntry] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return parse(content: content, relativeTo: fileURL)
    }

    /// The integer suffix of `key` when it starts with `prefix` (e.g.
    /// `"file12"` with prefix `"file"` -> 12), or nil otherwise.
    private static func trailingIndex(of key: String, prefix: String) -> Int? {
        guard key.hasPrefix(prefix) else { return nil }
        return Int(key.dropFirst(prefix.count))
    }

    private static func resolve(_ value: String, relativeTo baseURL: URL?) -> URL? {
        if let scheme = URL(string: value)?.scheme, !scheme.isEmpty,
           scheme != "file" || value.hasPrefix("file:") {
            return URL(string: value)
        }
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value)
        }
        if let base = baseURL {
            return URL(fileURLWithPath: value, relativeTo: base.deletingLastPathComponent()).standardizedFileURL
        }
        return URL(fileURLWithPath: value)
    }
}
