import Foundation
import GRDB

/// What scripture unit one ledger row generates for.
///
/// A selected chapter yields a `chapter` unit; a whole-book selection adds a
/// single `bookPrologue` unit ahead of its chapters. `bookPrologue` rows carry
/// no `chapterNumber`.
public enum BulkRunUnitKind: String, Codable, Sendable, Equatable, CaseIterable {
    case chapter
    case bookPrologue
}

/// One unit of work inside a run, persisted in `bulkAnnotationRunUnit` (FK to
/// `bulkAnnotationRun`, `ON DELETE CASCADE`). Ordered within its run by
/// `ordinal`; the engine walks them in that order, one at a time.
///
/// `state` reuses `BulkUnitState` (`queued · generating · done · failed`) so the
/// ledger, the `BulkRunSnapshot`, and the reader's chapter-row share one
/// vocabulary. `attemptCount` drives the per-unit retry tier; `producedCount` is
/// the number of annotations written once `.done`; `errorMessage` holds the last
/// failure reason for a `.failed` row's Retry affordance. `bookName` is
/// denormalized so a run renders its title without a catalog lookup.
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
