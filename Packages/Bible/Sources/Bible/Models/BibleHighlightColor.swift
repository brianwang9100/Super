import Core

/// Raw values are persisted colorId identifiers; renaming requires a migration.
public enum BibleHighlightColor: String, Codable, Sendable, CaseIterable, Identifiable {
    case yellow
    case green
    case blue
    case pink
    case lavender

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .pink: "Pink"
        case .lavender: "Lavender"
        }
    }

    public var swatch: OKLCH {
        switch self {
        case .yellow: OKLCH(0.92, 0.10, 95)
        case .green: OKLCH(0.88, 0.09, 150)
        case .blue: OKLCH(0.88, 0.06, 235)
        case .pink: OKLCH(0.86, 0.08, 350)
        case .lavender: OKLCH(0.88, 0.07, 295)
        }
    }

    /// Dark pages use a translucent, lower-chroma tint to preserve contrast with light ink.
    public func verseTint(forDarkPage isDark: Bool) -> OKLCH {
        guard isDark else { return swatch }
        return OKLCH(0.42, swatch.c * 0.85, swatch.h, alpha: 0.65)
    }
}
