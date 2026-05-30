import Testing
@testable import MacAmp

@Suite("BitrateFormatting", .tags(.skin))
struct BitrateFormattingTests {
    @Test("Values under 1000 right-align in three cells with leading blanks",
          arguments: [
            (128, "128"),
            (999, "999"),
            (96, " 96"),
            (8, "  8"),
            (0, "  0"),
          ])
    func underOneThousand(kbps: Int, expected: String) {
        #expect(BitrateFormatting.mainWindowCells(kbps: kbps) == expected)
    }

    @Test("1000–9999 abbreviates to two hundreds digits plus H",
          arguments: [
            (1000, "10H"),
            (1024, "10H"),
            (1411, "14H"),
            (9999, "99H"),
          ])
    func hundredsSuffix(kbps: Int, expected: String) {
        #expect(BitrateFormatting.mainWindowCells(kbps: kbps) == expected)
    }

    @Test("10000 and up abbreviates to ten-thousands digits plus C",
          arguments: [
            (10000, " 1C"),
            (24000, " 2C"),
            (100000, "10C"),
            (128000, "12C"),
            (999999, "99C"),
          ])
    func tenThousandsSuffix(kbps: Int, expected: String) {
        #expect(BitrateFormatting.mainWindowCells(kbps: kbps) == expected)
    }

    @Test("Negative input clamps to zero")
    func negativeClampsToZero() {
        #expect(BitrateFormatting.mainWindowCells(kbps: -1) == "  0")
    }

    @Test("Output is always exactly three cells",
          arguments: [0, 8, 96, 128, 999, 1000, 1411, 9999, 10000, 128000, 999999])
    func alwaysThreeCells(kbps: Int) {
        #expect(BitrateFormatting.mainWindowCells(kbps: kbps).count == 3)
    }
}
