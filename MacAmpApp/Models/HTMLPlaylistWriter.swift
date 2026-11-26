import Foundation

enum HTMLPlaylistWriter {
    enum RenderError: Error, Equatable { case durationOverflow }

    @concurrent
    static func write(tracks: [Track], to url: URL) async throws {
        let html = try render(tracks: tracks, destination: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try html.write(to: url, atomically: true, encoding: .utf8)
    }

    static func render(tracks: [Track], destination: URL) throws -> String {
        let lengths = tracks.map { track -> Int? in
            guard track.duration.isFinite, track.duration > 0 else { return nil }
            return Int(exactly: track.duration.rounded(.towardZero))
        }
        var html = """
        <!DOCTYPE html>
        <html lang="en"><head>
        <meta http-equiv="content-type" content="text/html; charset=UTF-8">
        <meta name="generator" content="Winamp 5.9">
        <style>body{background:#000040;font-family:arial,helvetica;font-size:9pt;font-weight:normal;}\
        .name{margin-top:-1em;margin-left:15px;font-size:40pt;color:#004080;text-align:left;font-weight:900;}\
        .name-small{margin-top:-3em;margin-left:140px;font-size:22pt;color:#E1E1E1;text-align:left;}\
        table{font-size:9pt;color:#004080;text-align:left;border-width:0px;padding:0px;letter-spacing:normal;}\
        hr{border:0;background-color:#FFBF00;height:1px;}\
        ol{color:#FFFFFF;font-size:11pt;}\
        table{margin-left:15px;color:#409FFF;border-width:0px;}\
        .val{color:#FFBF00;}\
        .header{color:#FFBF00;font-size:14pt;}</style>
        <title>Winamp Generated PlayList</title></head>
        <body><div><div class="name"><p>WINAMP</p></div>\
        <div class="name-small"><p>playlist</p></div></div><hr><div>
        <table><tr><td>
        """
        html += "\n" + (try summary(lengths: lengths, destination: destination))
        html += "</table></div>\n"
        if !tracks.isEmpty {
            html += "<blockquote><span class=\"header\">Playlist files:</span><ol>\n"
            for (track, length) in zip(tracks, lengths) {
                html += "<li>" + escape(track.playlistTitle)
                if let length, length > 0 { html += " (\(minutesAndSeconds(length)))" }
                html += " \n"
            }
            html += "</ol></blockquote>\n"
        }
        return html + "<hr><br></body></html>"
    }

    private static func summary(lengths: [Int?], destination: URL) throws -> String {
        let known = lengths.compactMap { $0 }
        guard !known.isEmpty else { return "There are no tracks in the current playlist.<br>" }
        let unknownCount = lengths.count - known.count
        var knownTotal = 0
        for length in known {
            let (sum, overflow) = knownTotal.addingReportingOverflow(length)
            guard !overflow else { throw RenderError.durationOverflow }
            knownTotal = sum
        }
        let average = knownTotal / known.count
        let estimated = Int128(knownTotal) + Int128(unknownCount) * Int128(knownTotal) / Int128(known.count)
        guard let total = Int(exactly: estimated) else { throw RenderError.durationOverflow }
        var result = "\(value(lengths.count)) track\(plural(lengths.count)) in playlist, "
        result += "average track length: <span class=\"val\">\(minutesAndSeconds(average))</span><br>"
        result += unknownCount > 0 ? "Estimated playlist length: " : "Playlist length: "
        if total / 3600 > 0 {
            result += "\(value(total / 3600)) hour\(plural(total / 3600)) "
        }
        if total % 3600 / 60 > 0 {
            result += "\(value(total % 3600 / 60)) minute\(plural(total % 3600 / 60)) "
        }
        result += "\(value(total % 60)) second\(plural(total % 60)) "
        if unknownCount > 0 {
            result += "<br>(\(value(unknownCount)) track\(plural(unknownCount)) of unknown length)"
        }
        result += "<br>Right-click <a href=\"\(escape(destination.absoluteString))\">here</a> to save this HTML file.</td></tr>"
        return result
    }

    private static func minutesAndSeconds(_ seconds: Int) -> String {
        "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }

    private static func value(_ number: Int) -> String { "<span class=\"val\">\(number)</span>" }
    private static func plural(_ number: Int) -> String { number == 1 ? "" : "s" }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
