import Foundation
import GRDB

/// A single moving cursor keyed by currentID; no per-book history.
public struct BibleReadingPositionRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "bibleReadingPosition"

    /// Always Self.currentID.
    public var id: String
    public var bookId: String
    /// 1-based chapter number.
    public var chapterNumber: Int
    /// Persisted BibleTranslation raw value.
    public var translationId: String
    public var updatedAt: Date

    public static let currentID = "current"

    public init(
        id: String = BibleReadingPositionRecord.currentID,
        bookId: String,
        chapterNumber: Int,
        translationId: String,
        updatedAt: Date
    ) {
        self.id = id
        self.bookId = bookId
        self.chapterNumber = chapterNumber
        self.translationId = translationId
        self.updatedAt = updatedAt
    }
}
