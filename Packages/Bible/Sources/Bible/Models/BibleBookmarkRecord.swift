import Foundation
import GRDB

/// Assignments are translation-independent and one-to-one between colors and chapters.
/// Unassigning hard-deletes; moving a ribbon creates a fresh row and createdAt timestamp.
public struct BibleBookmarkRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "bibleBookmark"

    public var id: String
    /// Persisted BibleBookmarkColor raw value.
    public var colorId: String
    public var bookId: String
    /// 1-based chapter number.
    public var chapterNumber: Int
    public var createdAt: Date

    public init(
        id: String,
        colorId: String,
        bookId: String,
        chapterNumber: Int,
        createdAt: Date
    ) {
        self.id = id
        self.colorId = colorId
        self.bookId = bookId
        self.chapterNumber = chapterNumber
        self.createdAt = createdAt
    }

    /// Unknown or retired color IDs render as empty slots.
    public var color: BibleBookmarkColor? {
        BibleBookmarkColor(rawValue: colorId)
    }
}
