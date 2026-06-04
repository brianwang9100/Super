// `import Combine` is mandatory (see `AnnotationCoverageRequest`): the
// `ValueObservationQueryable` conformance needs the `AnyPublisher: Publisher`
// conformance visible here. No Combine data flow is used.
import Combine
import Foundation
import GRDB
import GRDBQuery

/// GRDBQuery request observing the **finished** bulk runs the hub's "Recently
/// finished" section lists — terminal runs (`completedAt != nil`) that weren't a
/// user cancel, newest-completed first, each projected with its book names and
/// unit tallies.
///
/// The fetch reads both `bulkAnnotationRun` and `bulkAnnotationRunUnit`, so the
/// `@Query` re-fires when a run goes terminal (the runner writes the row), when a
/// run is dismissed (`deleteRun`), and when the 24 h sweep clears old rows —
/// keeping the section live without the view polling.
public struct FinishedRunsRequest: ValueObservationQueryable {
    public static var defaultValue: [FinishedRunSummary] { [] }

    public init() {}

    public func fetch(_ db: Database) throws -> [FinishedRunSummary] {
        // Terminal, non-cancelled runs, newest-completed first (`id` is a
        // deterministic tiebreak, matching `completedRuns()`).
        let runs = try BulkAnnotationRunRecord
            .filter(Column("completedAt") != nil)
            .filter(Column("status") != BulkRunStatus.cancelled.rawValue)
            .order(Column("completedAt").desc, Column("id").desc)
            .fetchAll(db)
        guard !runs.isEmpty else { return [] }

        // One pass over every listed run's units (ordinal order), grouped in
        // memory — cheaper and clearer than a correlated aggregate per run.
        let runIDs = runs.map(\.id)
        let units = try BulkAnnotationRunUnitRecord
            .filter(runIDs.contains(Column("runId")))
            .order(Column("ordinal").asc)
            .fetchAll(db)
        let unitsByRun = Dictionary(grouping: units, by: \.runId)

        return runs.map { run in
            let runUnits = unitsByRun[run.id] ?? []
            var seenBooks: Set<String> = []
            var bookNames: [String] = []
            var producedCount = 0
            var failedCount = 0
            for unit in runUnits {
                if seenBooks.insert(unit.bookId).inserted {
                    bookNames.append(unit.bookName)
                }
                if unit.state == .done { producedCount += unit.producedCount }
                if unit.state == .failed { failedCount += 1 }
            }
            return FinishedRunSummary(
                runID: run.id,
                status: run.status,
                haltReason: run.haltReason,
                completedAt: run.completedAt ?? run.updatedAt,
                bookNames: bookNames,
                producedCount: producedCount,
                failedCount: failedCount
            )
        }
    }
}
