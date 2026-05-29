import Foundation
import GRDB

/// One user- or assistant-authored note persisted in `bibleNote`.
///
/// The table is polymorphic: a row's `target` discriminates between book,
/// chapter, and verse-range scopes, and the optional position columns
/// (`chapterNumber`, `verseStart`, `verseEnd`) are filled per target:
///
/// - `target == .book` — only `bookId` set; other position columns nil.
/// - `target == .chapter` — `bookId` and `chapterNumber` set.
/// - `target == .verse` — `bookId`, `chapterNumber`, `verseStart`,
///   `verseEnd` all set (`verseEnd == verseStart` for a single verse).
///
/// A target can hold many notes — each renders as one card in the list sheet.
/// Notes are true per-row CRUD (created / edited / deleted individually),
/// unlike annotations' regenerate-the-whole-group model — so the record
/// carries both `createdAt` (the card's "date written") and `updatedAt`
/// (bumped on edit).
///
/// `source` is `.user` for a note typed in the editor or `.assistant` for one
/// the chat tool wrote; `modelId` stamps which LLM (Large Language Model)
/// produced an assistant note and is nil for user notes.
public struct BibleNoteRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "bibleNote"

    public var id: String
    public var target: BibleNoteTarget
    public var bookId: String
    public var chapterNumber: Int?
    public var verseStart: Int?
    public var verseEnd: Int?
    public var body: String
    public var source: BibleNoteSource
    public var modelId: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        target: BibleNoteTarget,
        bookId: String,
        chapterNumber: Int? = nil,
        verseStart: Int? = nil,
        verseEnd: Int? = nil,
        body: String,
        source: BibleNoteSource,
        modelId: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.target = target
        self.bookId = bookId
        self.chapterNumber = chapterNumber
        self.verseStart = verseStart
        self.verseEnd = verseEnd
        self.body = body
        self.source = source
        self.modelId = modelId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
