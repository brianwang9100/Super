import Testing
@testable import Core

/// Sanity coverage on the OKLCH (Oklab Lightness-Chroma-Hue) → sRGB
/// conversion pipeline. The transform is purely arithmetic, so a few
/// well-known anchor values are enough to catch drift if the matrix
/// constants ever change.
@Suite("OKLCH → sRGB conversion")
struct OKLCHTests {
    @Test("white round-trips to (1, 1, 1)")
    func whiteRoundTrips() {
        let (r, g, b) = OKLCH.toSRGB(l: 1.0, c: 0.0, h: 0.0)
        #expect(abs(r - 1.0) < 0.001)
        #expect(abs(g - 1.0) < 0.001)
        #expect(abs(b - 1.0) < 0.001)
    }

    @Test("black round-trips to (0, 0, 0)")
    func blackRoundTrips() {
        let (r, g, b) = OKLCH.toSRGB(l: 0.0, c: 0.0, h: 0.0)
        #expect(r == 0)
        #expect(g == 0)
        #expect(b == 0)
    }

    @Test("mid-gray (no chroma) is achromatic")
    func midGrayIsAchromatic() {
        let (r, g, b) = OKLCH.toSRGB(l: 0.5, c: 0.0, h: 90)
        #expect(abs(r - g) < 0.001)
        #expect(abs(g - b) < 0.001)
    }

    @Test("out-of-gamut colors clamp into [0, 1]")
    func outOfGamutClamps() {
        // Extreme chroma at red hue exceeds the sRGB gamut.
        let (r, g, b) = OKLCH.toSRGB(l: 0.5, c: 0.5, h: 30)
        #expect(r >= 0 && r <= 1)
        #expect(g >= 0 && g <= 1)
        #expect(b >= 0 && b <= 1)
    }
}

/// Smoke tests on `SuperTheme.make(_:)`. Verifies that all eight variants
/// (four families × light/dark) build without crashing, that `isDark` /
/// `family` / `displayName` track the identifier, and that a few transcribed
/// palette values land where the design file puts them.
@Suite("SuperTheme construction")
struct SuperThemeTests {
    @Test("every variant builds and isDark matches its mode")
    func allVariantsBuildWithCorrectMode() {
        for id in SuperTheme.Identifier.allCases {
            #expect(SuperTheme.make(id).isDark == id.isDark)
        }
    }

    @Test("there are exactly eight variants — four families × light/dark")
    func eightVariants() {
        #expect(SuperTheme.Identifier.allCases.count == 8)
        #expect(SuperTheme.Identifier.Family.allCases.count == 4)
        for family in SuperTheme.Identifier.Family.allCases {
            let variants = SuperTheme.Identifier.allCases.filter { $0.family == family }
            #expect(variants.count == 2)
            #expect(variants.filter(\.isDark).count == 1)
        }
    }

    @Test("the default theme is Vellum Light")
    func defaultIsVellumLight() {
        #expect(SuperThemeKey.defaultValue.id == .vellumLight)
        #expect(SuperThemeKey.defaultValue.isDark == false)
    }

    @Test("custom accent hue is propagated to the saturated accent")
    func accentHueIsParameterized() {
        let baseline = SuperTheme.make(.vellumLight)
        let shifted = SuperTheme.make(.vellumLight, accentHue: 30)
        #expect(baseline.accent != shifted.accent)
        #expect(baseline.accentDark != shifted.accentDark)
    }

    @Test("accent hue is exposed and defaults to the variant's design baseline")
    func accentHueIsExposed() {
        // Design accent hues from `palettes.jsx`.
        #expect(SuperTheme.make(.vellumLight).accentHue == 52)
        #expect(SuperTheme.make(.vellumDark).accentHue == 60)
        #expect(SuperTheme.make(.sepiaLight).accentHue == 50)
        #expect(SuperTheme.make(.scriptoriumLight).accentHue == 128)
        #expect(SuperTheme.make(.slateDark).accentHue == 52)
        #expect(SuperTheme.make(.vellumLight, accentHue: 30).accentHue == 30)
    }

    @Test("display name is the family name; mode label tracks light/dark")
    func displayNameIsFamily() {
        #expect(SuperTheme.make(.vellumLight).displayName == "Vellum")
        #expect(SuperTheme.make(.vellumDark).displayName == "Vellum")
        #expect(SuperTheme.make(.sepiaLight).displayName == "Sepia")
        #expect(SuperTheme.make(.scriptoriumDark).displayName == "Scriptorium")
        #expect(SuperTheme.make(.slateLight).displayName == "Slate")
        #expect(SuperTheme.Identifier.vellumLight.modeName == "Light")
        #expect(SuperTheme.Identifier.vellumDark.modeName == "Dark")
    }

    @Test("family grouping maps each variant to its family")
    func familyGrouping() {
        #expect(SuperTheme.Identifier.vellumDark.family == .vellum)
        #expect(SuperTheme.Identifier.sepiaLight.family == .sepia)
        #expect(SuperTheme.Identifier.scriptoriumDark.family == .scriptorium)
        #expect(SuperTheme.Identifier.slateLight.family == .slate)
    }

    @Test("Scriptorium's accent sits in the moss-olive band, replacing green")
    func scriptoriumAccentHueIsMossOlive() {
        // The old green accent was hue 150; Scriptorium pulls it to ~128–134.
        #expect(SuperTheme.make(.scriptoriumLight).accentHue == 128)
        #expect(SuperTheme.make(.scriptoriumDark).accentHue == 134)
    }
}
