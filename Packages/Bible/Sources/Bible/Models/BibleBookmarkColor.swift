import Core

/// The six fixed bookmark colours, each markable onto exactly one chapter.
///
/// The raw value is the stable identifier persisted in
/// `BibleBookmarkRecord.colorId`; never rename a case without a migration.
/// Unlike `BibleHighlightColor`'s pale washes, bookmark ribbons are saturated
/// mid-tones drawn from the SuperTheme families (Vellum clay, Lapis gold and
/// indigo, Scriptorium moss, the Bible applet's plum, Slate pewter) so they
/// read as ink-adjacent marks, not highlighter pastels.
public enum BibleBookmarkColor: String, Codable, Sendable, CaseIterable, Identifiable {
    case clay
    case gold
    case moss
    case lapis
    case plum
    case slate

    public var id: String { rawValue }

    /// Human-readable colour name — the label under each card in the
    /// bookmark sheet and the VoiceOver vocabulary ("Clay bookmark…").
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

    /// The ribbon tint, theme-aware the same way the highlight palette's
    /// `verseTint(forDarkPage:)` works: one hand-tuned light table, with the
    /// dark variant *derived* from it (lift lightness, trim chroma, keep the
    /// hue) so the two themes can never drift apart when a colour is tuned.
    /// Always opaque — a bookmark is a solid object, not a wash.
    /// - Parameter isDark: whether the active theme is a dark variant.
    public func tint(forDarkTheme isDark: Bool) -> OKLCH {
        guard isDark else { return lightTint }
        // Explicit alpha: the "solid object" contract, visible at the
        // construction site. (The light table follows the sibling
        // `BibleHighlightColor.swatch` style and leaves the default.)
        return OKLCH(lightTint.l + 0.19, lightTint.c * 0.88, lightTint.h, alpha: 1)
    }

    /// The pale wash that fills an *unassigned* slot's ribbon in the bookmark
    /// sheet and Bookmarks applet, so an empty slot still reads as its colour
    /// rather than a generic grey. Paired with the opaque `tint` as the ribbon
    /// outline. Derived from the filled tint the same theme-aware way
    /// `BibleHighlightColor.verseTint(forDarkPage:)` derives its dark wash: the
    /// light page lifts lightness and trims chroma to a pastel; the dark page
    /// keeps the (already lifted) tint but drops to a translucent fill so it
    /// composites as a wash, not a second solid ribbon.
    /// - Parameter isDark: whether the active theme is a dark variant.
    public func softTint(forDarkTheme isDark: Bool) -> OKLCH {
        let base = tint(forDarkTheme: isDark)
        // Lift relative to the filled tint (not a hard-coded lightness) so a
        // future darker colour still washes *lighter* than its filled ribbon;
        // clamp short of white so the pastel keeps a trace of its hue.
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
