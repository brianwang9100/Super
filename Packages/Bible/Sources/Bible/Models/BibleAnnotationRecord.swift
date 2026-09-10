import Foundation
import GRDB

/// A Markdown study summary using BibleAnnotationTarget's nullable position encoding.
/// replace(...) enforces one row per target; the schema has no position UNIQUE constraint,
/// so readers remain array-shaped and order by (createdAt ASC, id ASC).
/// modelId records provenance; an empty value is permitted.
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
