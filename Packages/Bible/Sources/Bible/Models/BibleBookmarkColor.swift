import Core

/// Raw values are persisted colorId identifiers; renaming requires a migration.
public enum BibleBookmarkColor: String, Codable, Sendable, CaseIterable, Identifiable {
    case clay
    case gold
    case moss
    case lapis
    case plum
    case slate

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .clay: "Clay"
        case .gold: "Gold"
        case .moss: "Moss"
        case .lapis: "Lapis"
        case .plum: "Plum"
        case .slate: "Slate"
        }
    }

    /// Opaque ribbon tint; dark colors derive from the light palette to keep hues aligned.
    public func tint(forDarkTheme isDark: Bool) -> OKLCH {
        guard isDark else { return lightTint }
        return OKLCH(lightTint.l + 0.19, lightTint.c * 0.88, lightTint.h, alpha: 1)
    }

    /// Wash for unassigned slots, paired with tint as an opaque outline.
    public func softTint(forDarkTheme isDark: Bool) -> OKLCH {
        let base = tint(forDarkTheme: isDark)
        // Lift relative to the filled tint; clamp below white to retain its hue.
        guard isDark else { return OKLCH(min(base.l + 0.38, 0.97), base.c * 0.5, base.h) }
        return OKLCH(base.l, base.c * 0.85, base.h, alpha: 0.32)
    }

    private var lightTint: OKLCH {
        switch self {
        case .clay: OKLCH(0.52, 0.11, 52)
        case .gold: OKLCH(0.58, 0.12, 78)
        case .moss: OKLCH(0.48, 0.10, 128)
        case .lapis: OKLCH(0.45, 0.11, 262)
        case .plum: OKLCH(0.50, 0.11, 330)
        case .slate: OKLCH(0.45, 0.025, 70)
        }
    }
}
