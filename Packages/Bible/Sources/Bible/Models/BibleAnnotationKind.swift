import Foundation

/// What an annotation card's `body` carries.
///
/// `.text` renders as markdown prose. `.reference` renders as a tappable
/// scripture-citation button — the `body` is a single citation string
/// (e.g. `"Heb 4:15"`, `"Romans 8:28-30"`) that `BibleCitationParser`
/// resolves at render time. A parse failure falls back to plain text,
/// so a malformed reference still surfaces its content to the reader.
public enum BibleAnnotationKind: String, Codable, Sendable, Equatable, CaseIterable {
    case text
    case reference
}
