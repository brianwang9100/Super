import Foundation

/// Persisted position encoding: book sets only bookId; chapter adds chapterNumber;
/// verse adds verseStart and verseEnd, equal for a single verse. Other positions are nil.
public enum BibleAnnotationTarget: String, Codable, Sendable, Equatable, CaseIterable {
    case book
    case chapter
    case verse
}
