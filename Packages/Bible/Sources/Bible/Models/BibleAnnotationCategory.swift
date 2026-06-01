import Foundation

/// The semantic role of an annotation card — and the single source of truth
/// for how the card sorts and renders.
///
/// Persisted as `Int` (1…5) so the SQLite column is a plain `INTEGER` and the
/// sheet's fetch can `ORDER BY category ASC` without a `CASE` expression. The
/// raw values *are* the canonical display order: author → summary → historical
/// → clarification → reference. Do not renumber without a migration — the
/// `Int` values are written to disk.
///
/// Card layout (`rendering`) is derived from the category, never stored
/// separately, so the illegal pairing "a `.summary` rendered as a citation"
/// is unrepresentable.
public enum BibleAnnotationCategory: Int, Codable, Sendable, CaseIterable, Equatable, Comparable {
    case author        = 1
    case summary       = 2
    case historical    = 3
    case clarification = 4
    case reference     = 5

    public static func < (lhs: BibleAnnotationCategory, rhs: BibleAnnotationCategory) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// How the card body is laid out. Derived from the category — a
    /// `.reference` is a citation, everything else is prose.
    public var rendering: BibleAnnotationRendering {
        self == .reference ? .citation : .prose
    }

    /// SF Symbol shown inside the accent category badge at the card's
    /// top-left. Nearest SF Symbol to each design-canvas glyph
    /// (`annotations/atoms.jsx` `CATEGORIES`).
    public var iconSystemName: String {
        switch self {
        case .author:        "person"
        case .summary:       "text.alignleft"
        case .historical:    "clock"
        case .clarification: "lightbulb"
        // Design's `ArrowJump` glyph — a diagonal ↗ that echoes the arrow on
        // the reference pill (`AnnotationBlock` uses the same symbol there).
        case .reference:     "arrow.up.forward"
        }
    }

    /// Human label for the badge's accessibility element.
    public var displayName: String {
        switch self {
        case .author:        "Author"
        case .summary:       "Summary"
        case .historical:    "Historical context"
        case .clarification: "Clarification"
        case .reference:     "Reference"
        }
    }

    /// Lowercase single-word token the `bible.annotate` tool accepts in each
    /// entry's `category` field. Kept distinct from `displayName` so the LLM
    /// surface is a stable enum vocabulary, not prose.
    public var toolToken: String {
        switch self {
        case .author:        "author"
        case .summary:       "summary"
        case .historical:    "historical"
        case .clarification: "clarification"
        case .reference:     "reference"
        }
    }

    /// Parse a tool-supplied `category` token. Returns `nil` for unknown
    /// values so the tool can reject the entry with a remediation message.
    public init?(toolToken: String) {
        guard let match = Self.allCases.first(where: { $0.toolToken == toolToken }) else {
            return nil
        }
        self = match
    }
}

/// How an annotation card's `body` is laid out. Derived from
/// `BibleAnnotationCategory.rendering` — never stored.
///
/// Cases are deliberately `.prose` / `.citation`, not `.text` / `.reference`:
/// `reference` now names a *category*, and reusing it at the rendering layer
/// would overload one word across two layers.
public enum BibleAnnotationRendering: Sendable, Equatable {
    /// Markdown prose body.
    case prose
    /// A single scripture citation string, parsed and rendered as a tappable
    /// pill.
    case citation
}
