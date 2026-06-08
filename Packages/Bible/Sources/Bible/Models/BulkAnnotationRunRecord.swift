import Foundation
import GRDB

/// Lifecycle status of one bulk-annotation run.
///
/// A run is **active** while it has work to do (`running`) or is parked by the
/// user (`paused`) — there is at most one active run at a time. It reaches a
/// **terminal** status exactly once: `completed` (every unit reached a terminal
/// state), `failed` (the run-level circuit breaker halted it — see
/// `BulkRunHaltReason`), or `cancelled` (the user tore it down). Terminal runs
/// carry a `completedAt` and feed the hub's Completed section + the 24 h sweep.
public enum BulkRunStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case running
    case paused
    case completed
    case failed
    case cancelled

    /// `true` while the run still owns the single-active-job slot.
    public var isActive: Bool { self == .running || self == .paused }
    /// `true` once the run has finished for good (completed / failed / cancelled).
    public var isTerminal: Bool { !isActive }
}

/// Why the run-level circuit breaker halted a run (`status == .failed`).
///
/// `auth` / `quota` are fatal provider errors that won't resolve on retry —
/// halting protects the user's wallet and surfaces a clear reason. `consecutiveFailures`
/// is the breaker tripping after N units fail in a row (a flaky model or network).
public enum BulkRunHaltReason: String, Codable, Sendable, Equatable, CaseIterable {
    case auth
    case quota
    case consecutiveFailures
}

/// One bulk-annotation run persisted in `bulkAnnotationRun` — the durable
/// counterpart of the in-memory `BulkRunSnapshot`. The engine resumes, retries,
/// and reports against this row + its `BulkAnnotationRunUnitRecord` children;
/// the completed-jobs lifecycle reads and sweeps it.
///
/// `modelId` is the model active at kickoff — stamped onto every annotation the
/// run produces so a later regenerate can tell bulk rows apart from per-target
/// taps. `haltReason` is set only when `status == .failed`. `completedAt` is set
/// only on a terminal status; it's the sort key for the Completed section and
/// the cutoff axis for `deleteRunsCompleted(before:)`. `overwriteExisting` is the
/// per-run preserve/overwrite choice from the Generate sheet: `false` (the
/// default) makes the runner skip a unit whose target slot is already annotated;
/// `true` regenerates and replaces it. Persisted so a relaunched/resumed run
/// honors the choice made at kickoff.
public struct BulkAnnotationRunRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "bulkAnnotationRun"

    public var id: String
    public var status: BulkRunStatus
    public var modelId: String
    public var haltReason: BulkRunHaltReason?
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var overwriteExisting: Bool

    public init(
        id: String,
        status: BulkRunStatus,
        modelId: String,
        haltReason: BulkRunHaltReason? = nil,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil,
        overwriteExisting: Bool = false
    ) {
        self.id = id
        self.status = status
        self.modelId = modelId
        self.haltReason = haltReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.overwriteExisting = overwriteExisting
    }
}
