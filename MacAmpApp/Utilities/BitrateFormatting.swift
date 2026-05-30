import Foundation

/// Shared formatting for the main window's bitrate readout.
enum BitrateFormatting {
    /// Format a kbps bitrate into the main window's fixed three-cell numeric
    /// readout, mirroring Winamp's `draw_bitmixrate` (Src/Winamp/draw_main.cpp).
    ///
    /// The field is always exactly three glyph cells wide so it never overruns
    /// the adjacent "kbps" label. Values under 1000 are right-aligned with
    /// leading blanks. Larger values are abbreviated to two significant digits
    /// plus a magnitude suffix: `H` (hundreds) for 1000–9999, `C`
    /// (ten-thousands) for 10000 and up.
    ///
    /// - Parameter kbps: bitrate in kilobits per second; negatives clamp to 0.
    /// - Returns: exactly three characters — digits `0`–`9`, blank spaces, and
    ///   at most one trailing `H`/`C` suffix.
    static func mainWindowCells(kbps: Int) -> String {
        let value = max(0, kbps)
        var cells: [Character] = [" ", " ", " "]

        if value / 10000 != 0 {
            if value / 100000 != 0 { cells[0] = digit((value / 100000) % 10) }
            cells[1] = digit((value / 10000) % 10)
            cells[2] = "C"
        } else if value / 1000 != 0 {
            cells[0] = digit((value / 1000) % 10)
            cells[1] = digit((value / 100) % 10)
            cells[2] = "H"
        } else {
            if value / 100 != 0 { cells[0] = digit((value / 100) % 10) }
            if value / 10 != 0 { cells[1] = digit((value / 10) % 10) }
            cells[2] = digit(value % 10)
        }

        return String(cells)
    }

    private static func digit(_ d: Int) -> Character {
        Character(String(d))
    }
}
