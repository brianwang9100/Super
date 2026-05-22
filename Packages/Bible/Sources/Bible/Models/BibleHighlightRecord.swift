import Foundation
import GRDB

/// One verse the reader has highlighted, persisted so the colour survives
/// navigation away and app relaunch.
///
/// At most one row ever exists per `(bookId, chapterNumber, verseNumber)`,
/// enforced by a UNIQUE index: re-highlighting a verse updates the row's
/// `colorId` in place rather than inserting a second. Clearing a highlight
/// soft-deletes the row (`deletedAt`) so a later re-highlight can restore it
/// without losing `createdAt` — and so a future sync engine sees a tombstone
/// rather than a vanished row.
///
/// Highlights are **translation-agnostic**: there is no `translationId`.
/// Verse numbers are shared across the bundled WEB / KJV / ASV / BSB, so a
/// verse highlighted while reading one translation stays highlighted in the
/// others. This is the design in the M6 plan, not an omission.
///
/// Two caveats the user can encounter:
/// 1. Critical-text translations (ASV, BSB) and the partially-hybrid WEB omit
///    a small set of textual-variant verses (e.g. Matthew 17:21, Acts 8:37);
///    KJV includes them. A highlight on one of those verses in KJV has no
///    equivalent verse to attach to in ASV/BSB, so the highlight is invisible
///    while reading those translations and re-appears in KJV.
/// 2. BSB folds Hebrew-style superscriptions ("For the choirmaster…", "A
///    Psalm of David.") into verse 1 of the psalms that have them, while
///    WEB/KJV/ASV emit the superscription as a heading and start verse 1 at
///    the body. The verse number lines up, but BSB's verse 1 text in those
///    psalms includes a leading line the other three render as a heading.
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
