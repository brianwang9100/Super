import Testing
@testable import Bible

@Suite("BibleHighlightColor")
struct BibleHighlightColorTests {
    @Test("the raw values are the stable identifiers persisted to the database")
    func rawValuesAreStable() {
        #expect(BibleHighlightColor.allCases.map(\.rawValue) == ["yellow", "green", "blue", "pink", "lavender"])
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
