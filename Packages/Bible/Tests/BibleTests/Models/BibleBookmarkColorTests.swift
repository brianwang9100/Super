import Testing
@testable import Bible

/// Tests for `BibleBookmarkColor` — the stable raw values persisted in
/// `BibleBookmarkRecord.colorId`, and the theme-aware ribbon tint.
@Suite("BibleBookmarkColor")
struct BibleBookmarkColorTests {
    @Test("the raw values are the stable identifiers persisted to the database")
    func rawValuesAreStable() {
        #expect(BibleBookmarkColor.clay.rawValue == "clay")
        #expect(BibleBookmarkColor.gold.rawValue == "gold")
        #expect(BibleBookmarkColor.moss.rawValue == "moss")
        #expect(BibleBookmarkColor.lapis.rawValue == "lapis")
        #expect(BibleBookmarkColor.plum.rawValue == "plum")
        #expect(BibleBookmarkColor.slate.rawValue == "slate")
    }

    @Test("the palette offers six colours")
    func paletteHasSixColours() {
        #expect(BibleBookmarkColor.allCases.count == 6)
    }

    @Test("the display names are the sheet's card labels and VoiceOver vocabulary")
    func displayNamesAreStable() {
        let names = BibleBookmarkColor.allCases.map(\.displayName)
        #expect(names == ["Clay", "Gold", "Moss", "Lapis", "Plum", "Slate"])
    }

    @Test("the dark tint lifts lightness and keeps the hue, fully opaque")
    func darkTintLiftsLightness() {
        for color in BibleBookmarkColor.allCases {
            let light = color.tint(forDarkTheme: false)
            let dark = color.tint(forDarkTheme: true)
            #expect(dark.l > light.l, "dark theme lifts lightness")
            #expect(dark.c <= light.c, "dark theme trims chroma")
            #expect(dark.h == light.h, "the hue is the colour's identity")
            #expect(light.alpha == 1 && dark.alpha == 1, "ribbons are opaque")
        }
    }

    @Test("the light soft tint is a paler, less saturated wash of the filled tint")
    func lightSoftTintIsPaler() {
        for color in BibleBookmarkColor.allCases {
            let filled = color.tint(forDarkTheme: false)
            let soft = color.softTint(forDarkTheme: false)
            #expect(soft.l > filled.l, "the empty wash lifts lightness")
            #expect(soft.c < filled.c, "the empty wash trims chroma")
            #expect(soft.h == filled.h, "the hue is the colour's identity")
            #expect(soft.alpha == 1, "the light-page wash is opaque over the page")
        }
    }

    @Test("the dark soft tint is a translucent wash that keeps the hue")
    func darkSoftTintIsTranslucent() {
        for color in BibleBookmarkColor.allCases {
            let filled = color.tint(forDarkTheme: true)
            let soft = color.softTint(forDarkTheme: true)
            #expect(soft.alpha < 1, "the dark-page wash is translucent so it reads as a tint")
            #expect(soft.c <= filled.c, "the dark wash trims chroma")
            #expect(soft.h == filled.h, "the hue is the colour's identity")
        }
    }

    @Test("an unknown persisted colorId decodes to a nil colour")
    func unknownColorIdIsNil() {
        let record = BibleBookmarkRecord(
            id: "bm-1",
            colorId: "retired-color",
            bookId: "JHN",
            chapterNumber: 3,
            createdAt: .init(timeIntervalSince1970: 0)
        )
        #expect(record.color == nil)
    }
}
