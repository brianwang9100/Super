import SwiftUI

private struct SuperFontScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

public extension EnvironmentValues {
    /// Unclamped app multiplier, default 1.0; Settings supplies about 0.80...1.20.
    /// SuperTypography accessors already apply it. Dynamic Type is an independent axis.
    var superFontScale: Double {
        get { self[SuperFontScaleKey.self] }
        set { self[SuperFontScaleKey.self] = newValue }
    }
}

public extension View {
    func superFontScale(_ scale: Double) -> some View {
        environment(\.superFontScale, scale)
    }
}
