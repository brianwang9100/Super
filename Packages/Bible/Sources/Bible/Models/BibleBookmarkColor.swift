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
        return OKLCH(lightTint.l + 0.19, lightTint.c * 0.88, lightTint.h)
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
