import SwiftUI

/// Resolved palette for one of Super's four "historical study bible" theme
/// families — **Vellum**, **Sepia**, **Scriptorium**, **Slate** — each with a
/// light and a dark variant (8 concrete variants). Vellum Light is the
/// default.
///
/// Token values are transcribed verbatim from the design artifact
/// `docs/design/palettes.jsx` (the `oklch(L C H)` triplets use the same
/// `L∈0–1` / absolute-chroma / degrees-hue convention as `OKLCH`, so they
/// drop straight into `OKLCH(L, C, H, alpha:)`). Construction resolves every
/// triplet once via `OKLCH.color`, so views read plain `Color` values per
/// render — there's no per-frame matrix math.
///
/// A handful of tokens the design file doesn't carry (`accentDark`,
/// `glassTint`, the fenced-code slab, the error reds) are *derived* per
/// variant from the transcribed palette — see `assemble(id:palette:accentHue:)`.
///
/// The accent hue is parameterized rather than baked. `make(_:accentHue:)`
/// seeds each variant with its design accent hue but accepts an override so a
/// future hue control can rebuild the active theme with a new `accentHue`
/// (today only `accent`/`accentDark` track it; the washes stay at their
/// designed hues).
public struct SuperTheme: Sendable, Equatable {
    /// Logical theme identity — one of four families × light/dark. Drives the
    /// system `colorScheme` adoption and the in-Settings selection state.
    public enum Identifier: String, Sendable, CaseIterable, Codable {
        case vellumLight
        case vellumDark
        case sepiaLight
        case sepiaDark
        case scriptoriumLight
        case scriptoriumDark
        case slateLight
        case slateDark

        /// The four theme families. Settings groups its variant cards under
        /// these as section headers; each family supplies a Light + Dark card.
        public enum Family: String, Sendable, CaseIterable, Codable {
            case vellum
            case sepia
            case scriptorium
            case slate

            public var displayName: String {
                switch self {
                case .vellum: "Vellum"
                case .sepia: "Sepia"
                case .scriptorium: "Scriptorium"
                case .slate: "Slate"
                }
            }
        }

        /// Which family this variant belongs to — used for Settings grouping
        /// and the theme's `displayName`.
        public var family: Family {
            switch self {
            case .vellumLight, .vellumDark: .vellum
            case .sepiaLight, .sepiaDark: .sepia
            case .scriptoriumLight, .scriptoriumDark: .scriptorium
            case .slateLight, .slateDark: .slate
            }
        }

        /// Whether this variant is the dark mode of its family.
        public var isDark: Bool {
            switch self {
            case .vellumDark, .sepiaDark, .scriptoriumDark, .slateDark: true
            case .vellumLight, .sepiaLight, .scriptoriumLight, .slateLight: false
            }
        }

        /// The mode label shown on a Settings card beneath the family header.
        public var modeName: String { isDark ? "Dark" : "Light" }
    }

    public let id: Identifier
    /// The family name ("Vellum" / "Sepia" / "Scriptorium" / "Slate"). The
    /// Settings card shows the mode ("Light"/"Dark") separately via
    /// `id.modeName`.
    public let displayName: String
    /// Whether the system should treat this as a dark color scheme — used
    /// by views that ask SwiftUI to pin `.preferredColorScheme(...)` so
    /// the iOS status bar adopts the matching style.
    public let isDark: Bool
    /// The accent hue (0–360°) this theme was built with — each variant's
    /// design baseline unless overridden via `make(_:accentHue:)`. Surfaced so
    /// derived washes (e.g. the Bible selection tint) can track the accent
    /// without re-deriving it from a resolved `Color`.
    public let accentHue: Double

    // Surfaces
    public let background: Color
    public let backgroundRaised: Color
    public let backgroundSunken: Color
    public let sidebar: Color

    // Ink (foreground)
    public let ink: Color
    public let inkSoft: Color
    public let inkFaint: Color
    public let inkMute: Color

    // Accent
    public let accent: Color
    public let accentInk: Color
    public let accentSoft: Color
    /// A deep, saturated accent for high-contrast marks (e.g. the splash
    /// spark glyph on the warm-light field). Tracks `accentHue` so a future
    /// hue control carries it; per mode it picks a lightness that stays
    /// legible against `background` (deep in light, mid in dark).
    public let accentDark: Color

    // Borders
    public let border: Color
    public let borderFaint: Color

    /// Low-alpha tint biasing the frosted Liquid Glass on chrome and sheets
    /// toward this theme's character — most load-bearing for the warm families,
    /// whose warmth the system glass (which only tracks light/dark) would
    /// otherwise drop. The alpha is deliberately low: the tint nudges the
    /// glass, it does not paint it. Read by `superGlassButton`/`superGlassSurface`.
    public let glassTint: Color

    // Code
    public let codeBackground: Color
    public let codeForeground: Color
    public let codeInlineBackground: Color
    public let codeInlineForeground: Color

    // Bubble
    public let bubbleUser: Color
    public let bubbleInk: Color

    // Error banner. The design uses a fixed warm-red (hue 30) across families;
    // we mirror that, picking the light or dark red set by mode.
    public let errorBackground: Color
    public let errorBorder: Color
    public let errorInk: Color
    public let errorAccent: Color

    /// Build a theme by id, optionally overriding the accent hue.
    /// `accentHue` defaults to the variant's design accent hue.
    public static func make(_ id: Identifier, accentHue: Double? = nil) -> SuperTheme {
        let p = palette(for: id)
        return assemble(id: id, palette: p, accentHue: accentHue ?? p.accent.h)
    }

    // MARK: - Palette transcription

    /// The raw, design-file token values for one variant. Everything here is
    /// transcribed 1:1 from `docs/design/palettes.jsx`; the derived tokens
    /// (`accentDark`, `glassTint`, code slab, error reds) are computed from
    /// these in `assemble`.
    private struct Palette {
        let bg, bgRaised, bgSunken, sidebar: OKLCH
        let ink, inkSoft, inkFaint, inkMute: OKLCH
        let accent, accentInk, accentSoft: OKLCH
        let border, borderFaint: OKLCH
        let codeInlineBg, codeInlineFg: OKLCH
        let bubbleUser, bubbleInk: OKLCH
        let isDark: Bool
    }

    /// The four warm-red error tokens for one mode. Not in `palettes.jsx`; the
    /// design uses a single fixed red set per mode across all families.
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

    /// Resolve the transcribed palette into a `SuperTheme`, deriving the
    /// tokens the design file omits:
    /// - `accentDark` — accent chroma/hue at a deeper (light) / mid (dark)
    ///   lightness for high-contrast marks.
    /// - `glassTint` — the variant's `bgRaised` at a low alpha (lighter in
    ///   light mode, slightly stronger in dark).
    /// - fenced-code slab — a dark warm slab keyed to the variant's bg hue.
    /// - error reds — the fixed light/dark warm-red set for this mode.
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
        case .sepiaLight: sepiaLight
        case .sepiaDark: sepiaDark
        case .scriptoriumLight: scriptoriumLight
        case .scriptoriumDark: scriptoriumDark
        case .slateLight: slateLight
        case .slateDark: slateDark
        }
    }

    /// Vellum — warm parchment cream, foxed at the edges; the brightest,
    /// softest reading surface. Clay accent (~hue 52).
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

    /// Sepia — an antique photograph, browner and warmer than vellum, with
    /// the patina of a much-handled book. Accent ~hue 50.
    private static let sepiaLight = Palette(
        bg: OKLCH(0.918, 0.034, 75), bgRaised: OKLCH(0.947, 0.027, 75),
        bgSunken: OKLCH(0.892, 0.040, 72), sidebar: OKLCH(0.902, 0.037, 73),
        ink: OKLCH(0.320, 0.035, 50), inkSoft: OKLCH(0.460, 0.034, 50),
        inkFaint: OKLCH(0.585, 0.029, 55), inkMute: OKLCH(0.720, 0.024, 60),
        accent: OKLCH(0.500, 0.100, 50), accentInk: OKLCH(0.970, 0.020, 80),
        accentSoft: OKLCH(0.852, 0.055, 65),
        border: OKLCH(0.812, 0.030, 65), borderFaint: OKLCH(0.862, 0.025, 68),
        codeInlineBg: OKLCH(0.862, 0.040, 65), codeInlineFg: OKLCH(0.400, 0.075, 48),
        bubbleUser: OKLCH(0.860, 0.050, 68), bubbleInk: OKLCH(0.300, 0.035, 50),
        isDark: false
    )

    private static let sepiaDark = Palette(
        bg: OKLCH(0.270, 0.022, 60), bgRaised: OKLCH(0.315, 0.024, 60),
        bgSunken: OKLCH(0.230, 0.020, 60), sidebar: OKLCH(0.250, 0.022, 60),
        ink: OKLCH(0.902, 0.025, 75), inkSoft: OKLCH(0.742, 0.025, 70),
        inkFaint: OKLCH(0.582, 0.022, 65), inkMute: OKLCH(0.442, 0.020, 60),
        accent: OKLCH(0.682, 0.090, 55), accentInk: OKLCH(0.192, 0.020, 55),
        accentSoft: OKLCH(0.360, 0.045, 58),
        border: OKLCH(0.372, 0.022, 60), borderFaint: OKLCH(0.320, 0.020, 60),
        codeInlineBg: OKLCH(0.330, 0.026, 60), codeInlineFg: OKLCH(0.820, 0.070, 65),
        bubbleUser: OKLCH(0.380, 0.035, 60), bubbleInk: OKLCH(0.902, 0.025, 75),
        isDark: true
    )

    /// Scriptorium — "your green, taken to seminary": a muted study sage with
    /// a moss-olive accent (~hue 128). The explicit replacement for the old
    /// green theme.
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

    /// Slate — monastic stone and pewter; a near-neutral warm grey that lets a
    /// single clay accent (~hue 48) do the talking. The most restrained family.
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

/// Environment slot for the active theme. Views read it via
/// `@Environment(\.superTheme)` and SwiftUI rebuilds them when the value
/// changes (e.g. theme switch in Settings).
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
    /// Inject a theme into the SwiftUI environment for this subtree, and
    /// pin the matching `colorScheme` so system chrome (status bar, native
    /// pickers, blur effects) adopts the right light/dark variant.
    func superTheme(_ theme: SuperTheme) -> some View {
        environment(\.superTheme, theme)
            .preferredColorScheme(theme.isDark ? .dark : .light)
    }
}
