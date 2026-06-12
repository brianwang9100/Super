import Foundation
import GRDB

/// One annotation persisted in `bibleAnnotation` — a long-form markdown
/// study summary of its target passage.
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
/// One row per target is the intended steady state — generation goes
/// through `replace(...)`, which clears the target's prior rows before
/// inserting. There is no UNIQUE constraint on the position tuple (the
/// nullable columns would need COALESCE gymnastics), so readers stay
/// array-shaped and render `first` defensively; ordering is
/// `(createdAt ASC, id ASC)`.
///
/// `summary` is markdown — headings, bold, lists, blockquotes, and
/// scripture citations that the shared renderer (`Core.MarkdownText`)
/// auto-links into tappable `super://bible/...` references.
///
/// `modelId` stamps which LLM (Large Language Model) produced the row — used
/// for the provenance footer and for future invalidation if a model
/// proves problematic. Empty string is permitted; tests substitute whatever
/// value they need.
public struct BibleAnnotationRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "bibleAnnotation"

    public var id: String
    public var target: BibleAnnotationTarget
    public var bookId: String
    public var chapterNumber: Int?
    public var verseStart: Int?
    public var verseEnd: Int?
    public var summary: String
    public var source: BibleAnnotationSource
    public var modelId: String
    public var createdAt: Date

    public init(
        id: String,
        target: BibleAnnotationTarget,
        bookId: String,
        chapterNumber: Int? = nil,
        verseStart: Int? = nil,
        verseEnd: Int? = nil,
        summary: String,
        source: BibleAnnotationSource,
        modelId: String,
        createdAt: Date
    ) {
        self.id = id
        self.target = target
        self.bookId = bookId
        self.chapterNumber = chapterNumber
        self.verseStart = verseStart
        self.verseEnd = verseEnd
        self.summary = summary
        self.source = source
        self.modelId = modelId
        self.createdAt = createdAt
    }
}
