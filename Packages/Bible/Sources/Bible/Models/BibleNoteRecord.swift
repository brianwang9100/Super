import Foundation
import GRDB

/// Uses BibleNoteTarget's nullable position encoding. Multiple notes per target are
/// edited individually; createdAt is the original date and updatedAt changes on edit.
/// User notes have nil modelId; assistant notes retain model provenance.
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
