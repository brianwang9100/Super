import SwiftUI

/// Resolved palette for one of Super's three themes (Light / Dark / Sepia).
///
/// Token names mirror `.design-tmp/chat/project/src/theme.jsx` so a designer
/// reading both files can reconcile each color side-by-side. Construction
/// resolves every OKLCH triplet once via `OKLCH.color` so views read plain
/// `Color` values per render — there's no per-frame matrix math.
///
/// The accent hue is parameterized rather than baked. Settings (M9) will
/// expose a 0–360° slider that round-trips through `SettingRecord` and
/// rebuilds the active `SuperTheme` with a new `accentHue`.
public struct SuperTheme: Sendable, Equatable {
    /// Logical theme identity. Drives the system `colorScheme` adoption
    /// and the in-Settings selection state.
    public enum Identifier: String, Sendable, CaseIterable, Codable {
        case light
        case dark
        case sepia
    }

    public let id: Identifier
    public let displayName: String
    /// Whether the system should treat this as a dark color scheme — used
    /// by views that ask SwiftUI to pin `.preferredColorScheme(...)` so
    /// the iOS status bar adopts the matching style.
    public let isDark: Bool
    /// The accent hue (0–360°) this theme was built with — the design
    /// baseline (150° Light/Dark, 80° Sepia) unless overridden via the
    /// Settings hue slider. Surfaced so derived washes (e.g. the Bible
    /// selection tint) can track the accent without re-deriving it from a
    /// resolved `Color`.
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
    /// spark glyph on the warm-light field). Tracks `accentHue` so the
    /// Settings hue slider carries it; per theme it picks a lightness that
    /// stays legible against `background`.
    public let accentDark: Color

    // Borders
    public let border: Color
    public let borderFaint: Color

    // Code
    public let codeBackground: Color
    public let codeForeground: Color
    public let codeInlineBackground: Color
    public let codeInlineForeground: Color

    // Bubble
    public let bubbleUser: Color
    public let bubbleInk: Color

    // Error banner. Not parameterized in `theme.jsx` (the design uses a
    // fixed warm-red across themes); we mirror that here.
    public let errorBackground: Color
    public let errorBorder: Color
    public let errorInk: Color
    public let errorAccent: Color

    /// Build a theme by id, optionally overriding the accent hue.
    /// `accentHue` defaults to the design's per-theme baseline (150° for
    /// Light/Dark, 80° for Sepia — matches `--accent` in `theme.jsx`).
    public static func make(_ id: Identifier, accentHue: Double? = nil) -> SuperTheme {
        switch id {
        case .light: return light(accentHue: accentHue ?? 150)
        case .dark:  return dark(accentHue: accentHue ?? 150)
        case .sepia: return sepia(accentHue: accentHue ?? 80)
        }
    }

    private static func light(accentHue h: Double) -> SuperTheme {
        SuperTheme(
            id: .light,
            displayName: "Light",
            isDark: false,
            accentHue: h,
            background:        OKLCH(0.965, 0.018, 150).color,
            backgroundRaised:  OKLCH(0.985, 0.012, 150).color,
            backgroundSunken:  OKLCH(0.945, 0.020, 150).color,
            sidebar:           OKLCH(0.955, 0.020, 150).color,
            ink:               OKLCH(0.32,  0.015, 200).color,
            inkSoft:           OKLCH(0.48,  0.012, 200).color,
            inkFaint:          OKLCH(0.62,  0.010, 200).color,
            inkMute:           OKLCH(0.78,  0.008, 180).color,
            accent:            OKLCH(0.52,  0.090, h).color,
            accentInk:         .white,
            accentSoft:        OKLCH(0.90,  0.035, h).color,
            accentDark:        OKLCH(0.32,  0.100, h).color,
            border:            OKLCH(0.88,  0.012, 180).color,
            borderFaint:       OKLCH(0.92,  0.010, 180).color,
            codeBackground:    OKLCH(0.32,  0.015, 200).color,
            codeForeground:    OKLCH(0.94,  0.010, 180).color,
            codeInlineBackground: OKLCH(0.92, 0.025, 150).color,
            codeInlineForeground: OKLCH(0.35, 0.050, 155).color,
            bubbleUser:        OKLCH(0.92,  0.030, 150).color,
            bubbleInk:         OKLCH(0.28,  0.020, 200).color,
            errorBackground:   OKLCH(0.93,  0.04,   30, alpha: 0.7).color,
            errorBorder:       OKLCH(0.75,  0.12,   30, alpha: 0.4).color,
            errorInk:          OKLCH(0.40,  0.12,   30).color,
            errorAccent:       OKLCH(0.55,  0.14,   30).color
        )
    }

    private static func dark(accentHue h: Double) -> SuperTheme {
        SuperTheme(
            id: .dark,
            displayName: "Dark",
            isDark: true,
            accentHue: h,
            background:        OKLCH(0.22, 0.025, 155).color,
            backgroundRaised:  OKLCH(0.27, 0.028, 155).color,
            backgroundSunken:  OKLCH(0.18, 0.022, 155).color,
            sidebar:           OKLCH(0.20, 0.025, 155).color,
            ink:               OKLCH(0.94, 0.010, 150).color,
            inkSoft:           OKLCH(0.78, 0.012, 150).color,
            inkFaint:          OKLCH(0.62, 0.015, 150).color,
            inkMute:           OKLCH(0.44, 0.018, 150).color,
            accent:            OKLCH(0.75, 0.10,  h).color,
            accentInk:         OKLCH(0.18, 0.02,  155).color,
            accentSoft:        OKLCH(0.34, 0.05,  h).color,
            accentDark:        OKLCH(0.62, 0.10,  h).color,
            border:            OKLCH(0.32, 0.025, 155).color,
            borderFaint:       OKLCH(0.27, 0.022, 155).color,
            codeBackground:    OKLCH(0.14, 0.018, 155).color,
            codeForeground:    OKLCH(0.90, 0.020, 150).color,
            codeInlineBackground: OKLCH(0.30, 0.035, 155).color,
            codeInlineForeground: OKLCH(0.88, 0.050, 150).color,
            bubbleUser:        OKLCH(0.32, 0.04,  150).color,
            bubbleInk:         OKLCH(0.94, 0.010, 150).color,
            errorBackground:   OKLCH(0.30, 0.05,   30, alpha: 0.6).color,
            errorBorder:       OKLCH(0.45, 0.12,   30, alpha: 0.5).color,
            errorInk:          OKLCH(0.85, 0.10,   30).color,
            errorAccent:       OKLCH(0.65, 0.14,   30).color
        )
    }

    private static func sepia(accentHue h: Double) -> SuperTheme {
        SuperTheme(
            id: .sepia,
            displayName: "Sepia",
            isDark: false,
            accentHue: h,
            background:        OKLCH(0.95, 0.035, 80).color,
            backgroundRaised:  OKLCH(0.97, 0.025, 80).color,
            backgroundSunken:  OKLCH(0.92, 0.040, 80).color,
            sidebar:           OKLCH(0.93, 0.040, 80).color,
            ink:               OKLCH(0.32, 0.030, 60).color,
            inkSoft:           OKLCH(0.48, 0.025, 60).color,
            inkFaint:          OKLCH(0.62, 0.020, 60).color,
            inkMute:           OKLCH(0.78, 0.015, 60).color,
            accent:            OKLCH(0.55, 0.13,  h).color,
            accentInk:         .white,
            accentSoft:        OKLCH(0.88, 0.05,  h).color,
            accentDark:        OKLCH(0.40, 0.13,  h).color,
            border:            OKLCH(0.85, 0.025, 70).color,
            borderFaint:       OKLCH(0.90, 0.020, 70).color,
            codeBackground:    OKLCH(0.30, 0.025, 60).color,
            codeForeground:    OKLCH(0.94, 0.020, 70).color,
            codeInlineBackground: OKLCH(0.90, 0.035, 70).color,
            codeInlineForeground: OKLCH(0.40, 0.080, 50).color,
            bubbleUser:        OKLCH(0.90, 0.045, 70).color,
            bubbleInk:         OKLCH(0.28, 0.030, 60).color,
            errorBackground:   OKLCH(0.93, 0.04,   30, alpha: 0.7).color,
            errorBorder:       OKLCH(0.75, 0.12,   30, alpha: 0.4).color,
            errorInk:          OKLCH(0.40, 0.12,   30).color,
            errorAccent:       OKLCH(0.55, 0.14,   30).color
        )
    }
}

/// Environment slot for the active theme. Views read it via
/// `@Environment(\.superTheme)` and SwiftUI rebuilds them when the value
/// changes (e.g. theme switch in Settings).
public struct SuperThemeKey: EnvironmentKey {
    public static let defaultValue: SuperTheme = .make(.light)
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
