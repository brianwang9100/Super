import Core

/// The five highlight colours a reader can paint onto a verse.
///
/// The raw value is the stable identifier persisted in
/// `BibleHighlightRecord.colorId`; never rename a case without a migration.
/// Each colour carries two renderings: the vivid `swatch` shown in the action
/// sheet, and the `verseTint` wash painted behind the highlighted words.
public enum BibleHighlightColor: String, Codable, Sendable, CaseIterable, Identifiable {
    case yellow
    case green
    case blue
    case pink
    case lavender

    public var id: String { rawValue }

    /// Human-readable colour name — used for the action sheet's VoiceOver
    /// labels (e.g. `"Highlight yellow"`).
    public var displayName: String {
        switch self {
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .pink: "Pink"
        case .lavender: "Lavender"
        }
    }

    /// The vivid pastel circle shown as the action sheet's selectable swatch.
    public var swatch: OKLCH {
        switch self {
        case .yellow: OKLCH(0.92, 0.10, 95)
        case .green: OKLCH(0.88, 0.09, 150)
        case .blue: OKLCH(0.88, 0.06, 235)
        case .pink: OKLCH(0.86, 0.08, 350)
        case .lavender: OKLCH(0.88, 0.07, 295)
        }
    }

    /// The wash painted behind a highlighted verse's words.
    ///
    /// Light and sepia pages reuse the pale `swatch` directly — it sits behind
    /// dark ink with ample contrast, the look of a physical highlighter. The
    /// dark page needs a deepened, lower-chroma, semi-transparent variant so
    /// the highlight reads as a tint without washing the light ink out.
    /// - Parameter isDark: whether the reader is on the dark theme.
    public func verseTint(forDarkPage isDark: Bool) -> OKLCH {
        guard isDark else { return swatch }
        return OKLCH(0.42, swatch.c * 0.85, swatch.h, alpha: 0.65)
    }
}
