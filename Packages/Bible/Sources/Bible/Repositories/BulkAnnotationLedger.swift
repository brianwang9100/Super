import Foundation

/// Durable store for bulk-annotation runs and their per-unit progress — the
/// authoritative state the real `BulkAnnotationRunner` (follow-on PR) drives,
/// and that the completed-jobs lifecycle reads and sweeps.
///
/// There is at most one **active** run (`status` running/paused) at a time;
/// `activeRun()` returns it. Terminal runs accumulate until the 24 h sweep
/// (`deleteRunsCompleted(before:)`) removes them. Deleting a run cascades to its
/// units via the `bulkAnnotationRunUnit` foreign key.
///
/// All timestamps are supplied by the caller (engine / tests) — the store never
/// reads the wall clock, matching the project's deterministic-clock convention.
public protocol BulkAnnotationLedger: Sendable {
    /// Insert a run and all its units in one transaction.
    func createRun(_ run: BulkAnnotationRunRecord, units: [BulkAnnotationRunUnitRecord]) async throws

    /// Fetch one run by id, or `nil` if it doesn't exist.
    func run(id: String) async throws -> BulkAnnotationRunRecord?

    /// The single active run (`status` running or paused), newest first if more
    /// than one ever coexisted; `nil` when only terminal runs (or none) exist.
    func activeRun() async throws -> BulkAnnotationRunRecord?

    /// A run's units in `ordinal` order.
    func units(runId: String) async throws -> [BulkAnnotationRunUnitRecord]

    /// Upsert a run row (status / completedAt transitions).
    func saveRun(_ run: BulkAnnotationRunRecord) async throws

    /// Upsert a unit row (state / attemptCount / producedCount / errorMessage).
    func saveUnit(_ unit: BulkAnnotationRunUnitRecord) async throws

    /// Terminal runs (`completedAt != nil`), newest-completed first — the
    /// Completed section's source.
    func completedRuns() async throws -> [BulkAnnotationRunRecord]

    /// Delete a run and (via FK cascade) its units.
    func deleteRun(id: String) async throws

    /// Sweep terminal runs whose `completedAt` is strictly before `cutoff`.
    /// Active runs (no `completedAt`) and newer terminal runs are left intact.
    func deleteRunsCompleted(before cutoff: Date) async throws
}
