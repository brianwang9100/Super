import Foundation
import GRDB

/// One row per verse, including cleared highlights. Re-highlighting restores the row
/// and preserves createdAt; deletedAt retains a tombstone for future sync.
///
/// Highlights are translation-independent. Omitted variant verses hide their highlight
/// until switching back to a translation containing them. BSB includes some Psalm
/// superscriptions in verse 1 where WEB/KJV/ASV render headings, so the same verse
/// highlight may cover different text.
public struct BibleHighlightRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "bibleHighlight"

    public var id: String
    public var bookId: String
    /// 1-based chapter number.
    public var chapterNumber: Int
    /// 1-based verse number within the chapter.
    public var verseNumber: Int
    /// Persisted BibleHighlightColor raw value.
    public var colorId: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Set when the highlight is cleared; `nil` while the highlight is active.
    public var deletedAt: Date?

    public init(
        id: String,
        bookId: String,
        chapterNumber: Int,
        verseNumber: Int,
        colorId: String,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.bookId = bookId
        self.chapterNumber = chapterNumber
        self.verseNumber = verseNumber
        self.colorId = colorId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var color: BibleHighlightColor? {
        BibleHighlightColor(rawValue: colorId)
    }
}
