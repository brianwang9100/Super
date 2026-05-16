import SwiftUI

/// App-wide font-size multiplier driven by the Settings → Appearance
/// slider (≈0.80×–1.20×, `1.0` = normal). Applets multiply their base
/// font sizes by this so one control scales text consistently across
/// every applet.
///
/// This is the shared, Core-level primitive — the Chat applet's richer
/// `ChatAppearance` (which also derives spacing) is constructed from the
/// same underlying setting. It composes with, rather than replaces, the
/// OS Dynamic Type setting: a view that also uses `@ScaledMetric` ends up
/// scaled by both. Mirrors the `\.superTheme` injection pattern.
private struct SuperFontScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

public extension EnvironmentValues {
    /// The active app-wide font-size multiplier. Defaults to `1.0`.
    var superFontScale: Double {
        get { self[SuperFontScaleKey.self] }
        set { self[SuperFontScaleKey.self] = newValue }
    }
}

public extension View {
    /// Inject the app-wide font scale into the environment for this
    /// subtree. Pair with `.superTheme(_:)` at the same composition
    /// boundary so theme and font scale refresh together.
    func superFontScale(_ scale: Double) -> some View {
        environment(\.superFontScale, scale)
    }
}
