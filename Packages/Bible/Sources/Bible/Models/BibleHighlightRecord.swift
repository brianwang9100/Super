import Foundation
import GRDB

/// One verse the reader has highlighted, persisted so the colour survives
/// navigation away and app relaunch.
///
/// At most one row ever exists per `(bookId, chapterNumber, verseNumber)`:
/// re-highlighting a verse updates the row's `colorId` in place rather than
/// inserting a second. Clearing a highlight soft-deletes the row (`deletedAt`)
/// so a later re-highlight can restore it without losing `createdAt` — and so
/// a future sync engine sees a tombstone rather than a vanished row.
public struct BibleHighlightRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "bibleHighlight"

    /// Stable UUID primary key.
    public var id: String
    /// Three-letter book code, e.g. `"1PE"`.
    public var bookId: String
    /// 1-based chapter number.
    public var chapterNumber: Int
    /// 1-based verse number within the chapter.
    public var verseNumber: Int
    /// The highlight colour — a `BibleHighlightColor` raw value.
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

    /// The decoded highlight colour, or `nil` if `colorId` holds a value no
    /// longer in `BibleHighlightColor` (a colour retired by a future build).
    public var color: BibleHighlightColor? {
        BibleHighlightColor(rawValue: colorId)
    }
}
