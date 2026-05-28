import Foundation

/// What scripture unit an annotation attaches to.
///
/// Discriminator on the polymorphic `bibleAnnotation` table. The optional
/// columns (`chapterNumber`, `verseStart`, `verseEnd`) are set per target:
/// `.book` carries only `bookId`, `.chapter` adds `chapterNumber`, `.verse`
/// adds both `verseStart` and `verseEnd` (equal for single-verse annotations).
public enum BibleAnnotationTarget: String, Codable, Sendable, Equatable, CaseIterable {
    case book
    case chapter
    case verse
}
