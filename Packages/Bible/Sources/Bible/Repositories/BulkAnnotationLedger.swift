import Foundation

/// One active run is allowed; deleting a run cascades to its units.
/// Callers supply timestamps; this store never reads the wall clock.
public protocol BulkAnnotationLedger: Sendable {
    /// Insert a run and all its units in one transaction.
    func createRun(_ run: BulkAnnotationRunRecord, units: [BulkAnnotationRunUnitRecord]) async throws

    func run(id: String) async throws -> BulkAnnotationRunRecord?

    /// Running/paused run, newest first if multiple exist; nil when none are active.
    func activeRun() async throws -> BulkAnnotationRunRecord?

    /// A run's units in `ordinal` order.
    func units(runId: String) async throws -> [BulkAnnotationRunUnitRecord]

    /// Upserts the run.
    func saveRun(_ run: BulkAnnotationRunRecord) async throws

    /// Upserts the unit.
    func saveUnit(_ unit: BulkAnnotationRunUnitRecord) async throws

    /// Terminal runs ordered newest-completed first.
    func completedRuns() async throws -> [BulkAnnotationRunRecord]

    /// Delete a run and (via FK cascade) its units.
    func deleteRun(id: String) async throws

    /// Deletes terminal runs strictly before cutoff; active runs remain.
    func deleteRunsCompleted(before cutoff: Date) async throws
}
