import Foundation
import GRDB

/// One bookmark slot's assignment — a colour ribbon marking a chapter.
///
/// At most six rows ever exist: one per `BibleBookmarkColor`, enforced by a
/// UNIQUE index on `colorId`; a second UNIQUE index on
/// `(bookId, chapterNumber)` keeps a chapter from carrying two ribbons. Rows
/// are hard-deleted on unassign (slots are state, not history — see the
/// `v8_createBookmark` migration comment), and every assignment — including
/// moving a ribbon between chapters — inserts a fresh row, so `createdAt`
/// is always *this assignment's* time and there is deliberately no
/// `updatedAt`: no code path updates a row in place.
///
/// Bookmarks are **translation-agnostic**: there is no `translationId`, so a
/// chapter bookmarked while reading one translation stays bookmarked in the
/// others — chapter numbering is shared across the bundled WEB / KJV / ASV /
/// BSB.
public struct BibleBookmarkRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "bibleBookmark"

    /// Stable UUID primary key.
    public var id: String
    /// The ribbon colour — a `BibleBookmarkColor` raw value.
    public var colorId: String
    /// Three-letter book code, e.g. `"JHN"`.
    public var bookId: String
    /// 1-based chapter number.
    public var chapterNumber: Int
    /// When this assignment was made — a moved ribbon gets a fresh row, so
    /// this is the time the ribbon landed on *this* chapter.
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

    /// The decoded ribbon colour, or `nil` if `colorId` holds a value no
    /// longer in `BibleBookmarkColor` (a colour retired by a future build) —
    /// callers render such a slot as empty rather than crashing.
    public var color: BibleBookmarkColor? {
        BibleBookmarkColor(rawValue: colorId)
    }
}
