import Foundation

/// Persisted position encoding: book sets only bookId; chapter adds chapterNumber;
/// verse adds verseStart and verseEnd, equal for one verse. Other positions are nil.
/// Kept separate from annotation targets so each feature can evolve independently.
public enum BibleNoteTarget: String, Codable, Sendable, Equatable, CaseIterable {
    case book
    case chapter
    case verse
}
