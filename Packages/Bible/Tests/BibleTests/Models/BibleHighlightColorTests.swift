import Testing
@testable import Bible

/// Tests for `BibleHighlightColor` — the stable raw values persisted in
/// `BibleHighlightRecord.colorId`, and the two-tier rendering (vivid swatch
/// vs. the page-aware verse tint).
@Suite("BibleHighlightColor")
struct BibleHighlightColorTests {
    @Test("the raw values are the stable identifiers persisted to the database")
    func rawValuesAreStable() {
        #expect(BibleHighlightColor.yellow.rawValue == "yellow")
        #expect(BibleHighlightColor.green.rawValue == "green")
        #expect(BibleHighlightColor.blue.rawValue == "blue")
        #expect(BibleHighlightColor.pink.rawValue == "pink")
        #expect(BibleHighlightColor.lavender.rawValue == "lavender")
    }

    @Test("the palette offers five colours")
    func paletteHasFiveColours() {
        #expect(BibleHighlightColor.allCases.count == 5)
    }

    @Test("the light verse tint reuses the vivid swatch")
    func lightTintIsTheSwatch() {
        for color in BibleHighlightColor.allCases {
            #expect(color.verseTint(forDarkPage: false) == color.swatch)
        }
    }

    @Test("the dark verse tint is deepened and semi-transparent")
    func darkTintIsDeepened() {
        for color in BibleHighlightColor.allCases {
            let dark = color.verseTint(forDarkPage: true)
            #expect(dark.l < color.swatch.l, "dark tint drops lightness")
            #expect(dark.alpha < 1, "dark tint is semi-transparent")
            #expect(dark.h == color.swatch.h, "dark tint keeps the hue")
        }
    }
}
