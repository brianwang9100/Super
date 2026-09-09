// Required for GRDBQuery's AnyPublisher conformance; data flow still uses @Query.
import Combine
import Foundation
import GRDB
import GRDBQuery

/// Excludes cancelled runs. Observes runs and units so completion, dismissal,
/// and history sweeps refresh the list.
public struct FinishedRunsRequest: ValueObservationQueryable {
    public static var defaultValue: [FinishedRunSummary] { [] }

    public init() {}

    public func fetch(_ db: Database) throws -> [FinishedRunSummary] {
        let runs = try BulkAnnotationRunRecord
            .filter(Column("completedAt") != nil)
            .filter(Column("status") != BulkRunStatus.cancelled.rawValue)
            .order(Column("completedAt").desc, Column("id").desc)
            .fetchAll(db)
        guard !runs.isEmpty else { return [] }

        // Fetch units in one pass to avoid a separate query per listed run.
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
