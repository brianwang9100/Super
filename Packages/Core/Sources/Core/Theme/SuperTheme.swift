import SwiftUI

/// Resolves palettes from docs/design/palettes.jsx once at construction. Tokens
/// absent from that artifact are derived in assemble; views read resolved Colors.
public struct SuperTheme: Sendable, Equatable {
    public enum Identifier: String, Sendable, CaseIterable, Codable {
        case vellumLight
        case vellumDark
        case lapisLight
        case lapisDark
        case scriptoriumLight
        case scriptoriumDark
        case slateLight
        case slateDark

        public enum Family: String, Sendable, CaseIterable, Codable {
            case vellum
            case lapis
            case scriptorium
            case slate

            public var displayName: String {
                switch self {
                case .vellum: "Vellum"
                case .lapis: "Lapis"
                case .scriptorium: "Scriptorium"
                case .slate: "Slate"
                }
            }
        }

        public var family: Family {
            switch self {
            case .vellumLight, .vellumDark: .vellum
            case .lapisLight, .lapisDark: .lapis
            case .scriptoriumLight, .scriptoriumDark: .scriptorium
            case .slateLight, .slateDark: .slate
            }
        }

        public var isDark: Bool {
            switch self {
            case .vellumDark, .lapisDark, .scriptoriumDark, .slateDark: true
            case .vellumLight, .lapisLight, .scriptoriumLight, .slateLight: false
            }
        }

        public var modeName: String { isDark ? "Dark" : "Light" }
    }

    public let id: Identifier
    /// Family name; modeName supplies the separate Light/Dark label.
    public let displayName: String
    public let isDark: Bool
    /// Accent hue in degrees, 0...360.
    public let accentHue: Double

    public let background: Color
    public let backgroundRaised: Color
    public let backgroundSunken: Color
    public let sidebar: Color

    public let ink: Color
    public let inkSoft: Color
    public let inkFaint: Color
    public let inkMute: Color

    public let accent: Color
    public let accentInk: Color
    public let accentSoft: Color
    /// High-contrast accent mark color adjusted for background brightness.
    public let accentDark: Color

    public let border: Color
    public let borderFaint: Color

    /// Low-alpha color bias for frosted glass; tints the material without painting over it.
    public let glassTint: Color

    public let codeBackground: Color
    public let codeForeground: Color
    public let codeInlineBackground: Color
    public let codeInlineForeground: Color

    public let bubbleUser: Color
    public let bubbleInk: Color

    public let errorBackground: Color
    public let errorBorder: Color
    public let errorInk: Color
    public let errorAccent: Color

    /// Nil accentHue uses the variant's design default; only derived accent tokens follow overrides.
    public static func make(_ id: Identifier, accentHue: Double? = nil) -> SuperTheme {
        let p = palette(for: id)
        return assemble(id: id, palette: p, accentHue: accentHue ?? p.accent.h)
    }

    // MARK: - Palette transcription

    private struct Palette {
        let bg, bgRaised, bgSunken, sidebar: OKLCH
        let ink, inkSoft, inkFaint, inkMute: OKLCH
        let accent, accentInk, accentSoft: OKLCH
        let border, borderFaint: OKLCH
        let codeInlineBg, codeInlineFg: OKLCH
        let bubbleUser, bubbleInk: OKLCH
        let isDark: Bool
    }

    // Error colors use one warm-red set per mode across all families.
    private struct ErrorPalette {
        let background, border, ink, accent: OKLCH
    }

    private static let lightError = ErrorPalette(
        background: OKLCH(0.93, 0.04, 30, alpha: 0.7),
        border: OKLCH(0.75, 0.12, 30, alpha: 0.4),
        ink: OKLCH(0.40, 0.12, 30),
        accent: OKLCH(0.55, 0.14, 30)
    )

    private static let darkError = ErrorPalette(
        background: OKLCH(0.30, 0.05, 30, alpha: 0.6),
        border: OKLCH(0.45, 0.12, 30, alpha: 0.5),
        ink: OKLCH(0.85, 0.10, 30),
        accent: OKLCH(0.65, 0.14, 30)
    )

    private static func assemble(id: Identifier, palette p: Palette, accentHue h: Double) -> SuperTheme {
        let darkMode = p.isDark
        let err = darkMode ? darkError : lightError
        return SuperTheme(
            id: id,
            displayName: id.family.displayName,
            isDark: darkMode,
            accentHue: h,
            background:        p.bg.color,
            backgroundRaised:  p.bgRaised.color,
            backgroundSunken:  p.bgSunken.color,
            sidebar:           p.sidebar.color,
            ink:               p.ink.color,
            inkSoft:           p.inkSoft.color,
            inkFaint:          p.inkFaint.color,
            inkMute:           p.inkMute.color,
            accent:            OKLCH(p.accent.l, p.accent.c, h).color,
            accentInk:         p.accentInk.color,
            accentSoft:        p.accentSoft.color,
            accentDark:        OKLCH(darkMode ? 0.57 : 0.36, p.accent.c, h).color,
            border:            p.border.color,
            borderFaint:       p.borderFaint.color,
            glassTint:         OKLCH(p.bgRaised.l, p.bgRaised.c, p.bgRaised.h, alpha: darkMode ? 0.22 : 0.18).color,
            codeBackground:    OKLCH(darkMode ? 0.16 : 0.30, darkMode ? 0.016 : 0.020, p.bg.h).color,
            codeForeground:    OKLCH(darkMode ? 0.90 : 0.94, darkMode ? 0.016 : 0.014, p.bg.h).color,
            codeInlineBackground: p.codeInlineBg.color,
            codeInlineForeground: p.codeInlineFg.color,
            bubbleUser:        p.bubbleUser.color,
            bubbleInk:         p.bubbleInk.color,
            errorBackground:   err.background.color,
            errorBorder:       err.border.color,
            errorInk:          err.ink.color,
            errorAccent:       err.accent.color
        )
    }

    // MARK: - The four families (verbatim from `docs/design/palettes.jsx`)

    private static func palette(for id: Identifier) -> Palette {
        switch id {
        case .vellumLight: vellumLight
        case .vellumDark: vellumDark
        case .lapisLight: lapisLight
        case .lapisDark: lapisDark
        case .scriptoriumLight: scriptoriumLight
        case .scriptoriumDark: scriptoriumDark
        case .slateLight: slateLight
        case .slateDark: slateDark
        }
    }

    private static let vellumLight = Palette(
        bg: OKLCH(0.957, 0.018, 85), bgRaised: OKLCH(0.978, 0.012, 85),
        bgSunken: OKLCH(0.936, 0.022, 84), sidebar: OKLCH(0.946, 0.020, 85),
        ink: OKLCH(0.305, 0.020, 60), inkSoft: OKLCH(0.460, 0.020, 60),
        inkFaint: OKLCH(0.600, 0.017, 62), inkMute: OKLCH(0.760, 0.013, 70),
        accent: OKLCH(0.520, 0.090, 52), accentInk: OKLCH(0.985, 0.010, 85),
        accentSoft: OKLCH(0.900, 0.040, 70),
        border: OKLCH(0.860, 0.018, 80), borderFaint: OKLCH(0.912, 0.013, 80),
        codeInlineBg: OKLCH(0.910, 0.030, 80), codeInlineFg: OKLCH(0.400, 0.060, 50),
        bubbleUser: OKLCH(0.902, 0.035, 80), bubbleInk: OKLCH(0.285, 0.020, 60),
        isDark: false
    )

    private static let vellumDark = Palette(
        bg: OKLCH(0.255, 0.013, 70), bgRaised: OKLCH(0.300, 0.015, 70),
        bgSunken: OKLCH(0.215, 0.011, 70), sidebar: OKLCH(0.235, 0.013, 70),
        ink: OKLCH(0.920, 0.015, 85), inkSoft: OKLCH(0.760, 0.015, 85),
        inkFaint: OKLCH(0.600, 0.015, 80), inkMute: OKLCH(0.450, 0.014, 75),
        accent: OKLCH(0.715, 0.082, 60), accentInk: OKLCH(0.200, 0.020, 60),
        accentSoft: OKLCH(0.345, 0.040, 65),
        border: OKLCH(0.360, 0.013, 70), borderFaint: OKLCH(0.310, 0.011, 70),
        codeInlineBg: OKLCH(0.320, 0.020, 70), codeInlineFg: OKLCH(0.840, 0.060, 70),
        bubbleUser: OKLCH(0.372, 0.025, 70), bubbleInk: OKLCH(0.920, 0.015, 85),
        isDark: true
    )

    private static let lapisLight = Palette(
        bg: OKLCH(0.945, 0.012, 255), bgRaised: OKLCH(0.972, 0.009, 255),
        bgSunken: OKLCH(0.922, 0.017, 255), sidebar: OKLCH(0.934, 0.014, 255),
        ink: OKLCH(0.312, 0.035, 262), inkSoft: OKLCH(0.455, 0.034, 262),
        inkFaint: OKLCH(0.590, 0.028, 258), inkMute: OKLCH(0.750, 0.018, 256),
        accent: OKLCH(0.585, 0.095, 75), accentInk: OKLCH(0.260, 0.030, 262),
        accentSoft: OKLCH(0.880, 0.045, 80),
        border: OKLCH(0.855, 0.015, 255), borderFaint: OKLCH(0.908, 0.010, 255),
        codeInlineBg: OKLCH(0.905, 0.022, 255), codeInlineFg: OKLCH(0.400, 0.060, 265),
        bubbleUser: OKLCH(0.895, 0.028, 255), bubbleInk: OKLCH(0.290, 0.035, 262),
        isDark: false
    )

    private static let lapisDark = Palette(
        bg: OKLCH(0.250, 0.030, 262), bgRaised: OKLCH(0.298, 0.034, 262),
        bgSunken: OKLCH(0.212, 0.028, 262), sidebar: OKLCH(0.232, 0.030, 262),
        ink: OKLCH(0.910, 0.018, 250), inkSoft: OKLCH(0.750, 0.020, 252),
        inkFaint: OKLCH(0.595, 0.022, 255), inkMute: OKLCH(0.450, 0.024, 258),
        accent: OKLCH(0.760, 0.085, 78), accentInk: OKLCH(0.220, 0.030, 262),
        accentSoft: OKLCH(0.355, 0.045, 70),
        border: OKLCH(0.360, 0.028, 262), borderFaint: OKLCH(0.308, 0.026, 262),
        codeInlineBg: OKLCH(0.325, 0.034, 262), codeInlineFg: OKLCH(0.830, 0.075, 80),
        bubbleUser: OKLCH(0.375, 0.038, 262), bubbleInk: OKLCH(0.910, 0.018, 250),
        isDark: true
    )

    private static let scriptoriumLight = Palette(
        bg: OKLCH(0.956, 0.012, 135), bgRaised: OKLCH(0.976, 0.008, 135),
        bgSunken: OKLCH(0.935, 0.016, 134), sidebar: OKLCH(0.945, 0.014, 135),
        ink: OKLCH(0.308, 0.020, 150), inkSoft: OKLCH(0.460, 0.018, 150),
        inkFaint: OKLCH(0.600, 0.015, 145), inkMute: OKLCH(0.760, 0.012, 140),
        accent: OKLCH(0.480, 0.070, 128), accentInk: OKLCH(0.985, 0.010, 135),
        accentSoft: OKLCH(0.890, 0.035, 135),
        border: OKLCH(0.860, 0.014, 140), borderFaint: OKLCH(0.912, 0.010, 140),
        codeInlineBg: OKLCH(0.908, 0.028, 138), codeInlineFg: OKLCH(0.400, 0.055, 130),
        bubbleUser: OKLCH(0.900, 0.028, 135), bubbleInk: OKLCH(0.285, 0.020, 150),
        isDark: false
    )

    private static let scriptoriumDark = Palette(
        bg: OKLCH(0.255, 0.018, 150), bgRaised: OKLCH(0.300, 0.020, 150),
        bgSunken: OKLCH(0.215, 0.016, 150), sidebar: OKLCH(0.235, 0.018, 150),
        ink: OKLCH(0.912, 0.013, 140), inkSoft: OKLCH(0.752, 0.014, 145),
        inkFaint: OKLCH(0.592, 0.015, 145), inkMute: OKLCH(0.442, 0.016, 148),
        accent: OKLCH(0.682, 0.078, 134), accentInk: OKLCH(0.192, 0.020, 150),
        accentSoft: OKLCH(0.342, 0.040, 145),
        border: OKLCH(0.360, 0.018, 150), borderFaint: OKLCH(0.310, 0.016, 150),
        codeInlineBg: OKLCH(0.322, 0.024, 148), codeInlineFg: OKLCH(0.820, 0.065, 140),
        bubbleUser: OKLCH(0.372, 0.030, 148), bubbleInk: OKLCH(0.912, 0.013, 140),
        isDark: true
    )

    private static let slateLight = Palette(
        bg: OKLCH(0.957, 0.004, 80), bgRaised: OKLCH(0.979, 0.003, 80),
        bgSunken: OKLCH(0.936, 0.005, 80), sidebar: OKLCH(0.946, 0.005, 80),
        ink: OKLCH(0.312, 0.007, 70), inkSoft: OKLCH(0.462, 0.006, 70),
        inkFaint: OKLCH(0.602, 0.005, 70), inkMute: OKLCH(0.762, 0.004, 70),
        accent: OKLCH(0.522, 0.080, 48), accentInk: OKLCH(0.985, 0.005, 80),
        accentSoft: OKLCH(0.900, 0.030, 58),
        border: OKLCH(0.870, 0.005, 75), borderFaint: OKLCH(0.920, 0.004, 75),
        codeInlineBg: OKLCH(0.912, 0.006, 75), codeInlineFg: OKLCH(0.420, 0.060, 48),
        bubbleUser: OKLCH(0.910, 0.012, 70), bubbleInk: OKLCH(0.292, 0.008, 70),
        isDark: false
    )

    private static let slateDark = Palette(
        bg: OKLCH(0.250, 0.005, 70), bgRaised: OKLCH(0.295, 0.006, 70),
        bgSunken: OKLCH(0.212, 0.004, 70), sidebar: OKLCH(0.232, 0.005, 70),
        ink: OKLCH(0.912, 0.005, 80), inkSoft: OKLCH(0.742, 0.005, 80),
        inkFaint: OKLCH(0.582, 0.005, 75), inkMute: OKLCH(0.442, 0.005, 72),
        accent: OKLCH(0.702, 0.072, 52), accentInk: OKLCH(0.190, 0.010, 60),
        accentSoft: OKLCH(0.342, 0.035, 58),
        border: OKLCH(0.352, 0.005, 70), borderFaint: OKLCH(0.302, 0.005, 70),
        codeInlineBg: OKLCH(0.320, 0.006, 70), codeInlineFg: OKLCH(0.820, 0.060, 55),
        bubbleUser: OKLCH(0.370, 0.010, 70), bubbleInk: OKLCH(0.912, 0.005, 80),
        isDark: true
    )
}

public struct SuperThemeKey: EnvironmentKey {
    public static let defaultValue: SuperTheme = .make(.vellumLight)
}

public extension EnvironmentValues {
    var superTheme: SuperTheme {
        get { self[SuperThemeKey.self] }
        set { self[SuperThemeKey.self] = newValue }
    }
}

public extension View {
    /// Also pins the preferred color scheme so native chrome follows the theme.
    func superTheme(_ theme: SuperTheme) -> some View {
        environment(\.superTheme, theme)
            .preferredColorScheme(theme.isDark ? .dark : .light)
    }
}
