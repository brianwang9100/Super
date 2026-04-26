import Testing
@testable import Chat

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

/// Smoke tests on `SuperTheme.make(_:)`. Verifies that all three themes
/// build without crashing and that `isDark` matches the design's intent.
@Suite("SuperTheme construction")
struct SuperThemeTests {
    @Test("light theme is not dark")
    func lightIsNotDark() {
        #expect(SuperTheme.make(.light).isDark == false)
    }

    @Test("dark theme is dark")
    func darkIsDark() {
        #expect(SuperTheme.make(.dark).isDark == true)
    }

    @Test("sepia theme is not dark")
    func sepiaIsNotDark() {
        #expect(SuperTheme.make(.sepia).isDark == false)
    }

    @Test("custom accent hue is propagated")
    func accentHueIsParameterized() {
        let baseline = SuperTheme.make(.light)
        let shifted = SuperTheme.make(.light, accentHue: 30)
        #expect(baseline.accent != shifted.accent)
    }

    @Test("display name matches identifier")
    func displayNameMatchesId() {
        #expect(SuperTheme.make(.light).displayName == "Light")
        #expect(SuperTheme.make(.dark).displayName == "Dark")
        #expect(SuperTheme.make(.sepia).displayName == "Sepia")
    }
}
