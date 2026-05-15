import Foundation
import GRDB

/// The reader's last-open chapter, persisted so a relaunch lands where they
/// left off.
///
/// Exactly one row ever exists, keyed by the constant `id` `"current"`:
/// there is no per-book history, just a single moving cursor. `translationId`
/// holds a `BibleTranslation` raw value — the reader's chosen translation.
public struct BibleReadingPositionRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "bibleReadingPosition"

    /// The sole row's primary key — always `Self.currentID`.
    public var id: String
    /// Three-letter book code, e.g. `"1PE"`.
    public var bookId: String
    /// 1-based chapter number.
    public var chapterNumber: Int
    /// Translation short code — a `BibleTranslation` raw value, e.g. `"KJV"`.
    public var translationId: String
    public var updatedAt: Date

    /// The fixed primary key of the single reading-position row.
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
