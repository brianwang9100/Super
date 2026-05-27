import Foundation
import GRDB

/// One annotation card persisted in `bibleAnnotation`.
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
/// A book / chapter / verse range can have multiple rows — each renders as
/// a separate card in the popover. Ordering is `(createdAt ASC, id ASC)`.
///
/// `body` interpretation depends on `kind`:
/// - `.text` — markdown prose
/// - `.reference` — a single citation string ("Heb 4:15", "Romans 8:28-30")
///   parsed by `BibleCitationParser` at render time; a parse failure falls
///   back to plain text.
///
/// `modelId` stamps which LLM (Large Language Model) produced the row — used
/// for the per-card provenance footer and for future invalidation if a model
/// proves problematic. Empty string is permitted; the integration milestone
/// wires the active session's model id, and tests substitute whatever value
/// they need.
public struct BibleAnnotationRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "bibleAnnotation"

    public var id: String
    public var target: BibleAnnotationTarget
    public var bookId: String
    public var chapterNumber: Int?
    public var verseStart: Int?
    public var verseEnd: Int?
    public var kind: BibleAnnotationKind
    public var title: String
    public var body: String
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
        kind: BibleAnnotationKind,
        title: String,
        body: String,
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
        self.kind = kind
        self.title = title
        self.body = body
        self.source = source
        self.modelId = modelId
        self.createdAt = createdAt
    }
}
