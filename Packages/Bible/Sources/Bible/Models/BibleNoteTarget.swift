import Foundation

/// What scripture unit a note attaches to.
///
/// Discriminator on the polymorphic `bibleNote` table. The optional columns
/// (`chapterNumber`, `verseStart`, `verseEnd`) are set per target: `.book`
/// carries only `bookId`, `.chapter` adds `chapterNumber`, `.verse` adds both
/// `verseStart` and `verseEnd` (equal for a single-verse note).
///
/// Deliberately separate from `BibleAnnotationTarget` even though the cases
/// match — notes and annotations are decoupled features, and coupling their
/// enums would let a change to one silently reshape the other.
public enum BibleNoteTarget: String, Codable, Sendable, Equatable, CaseIterable {
    case book
    case chapter
    case verse
}
