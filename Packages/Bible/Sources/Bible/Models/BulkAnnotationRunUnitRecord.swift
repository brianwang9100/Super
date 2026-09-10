import Foundation
import GRDB

/// Whole-book selections prepend a bookPrologue with nil chapterNumber. Notable-verse
/// generation adds a chapterVerses unit after each chapter, sharing its number and
/// generating selected verse ranges in one dispatch.
public enum BulkRunUnitKind: String, Codable, Sendable, Equatable, CaseIterable {
    case chapter
    case bookPrologue
    case chapterVerses
}

/// Units execute serially by ordinal. producedCount counts saved annotations;
/// bookName is denormalized so history needs no catalog lookup.
public struct BulkAnnotationRunUnitRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "bulkAnnotationRunUnit"

    public var id: String
    public var runId: String
    public var ordinal: Int
    public var kind: BulkRunUnitKind
    public var bookId: String
    public var bookName: String
    public var chapterNumber: Int?
    public var state: BulkUnitState
    public var attemptCount: Int
    public var producedCount: Int
    public var errorMessage: String?
    public var updatedAt: Date

    public init(
        id: String,
        runId: String,
        ordinal: Int,
        kind: BulkRunUnitKind,
        bookId: String,
        bookName: String,
        chapterNumber: Int? = nil,
        state: BulkUnitState = .queued,
        attemptCount: Int = 0,
        producedCount: Int = 0,
        errorMessage: String? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.runId = runId
        self.ordinal = ordinal
        self.kind = kind
        self.bookId = bookId
        self.bookName = bookName
        self.chapterNumber = chapterNumber
        self.state = state
        self.attemptCount = attemptCount
        self.producedCount = producedCount
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
    }
}
