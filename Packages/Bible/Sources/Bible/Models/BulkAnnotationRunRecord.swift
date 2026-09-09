import Foundation
import GRDB

/// Running and paused runs own the single active slot. Terminal runs carry
/// completedAt for history and the 24-hour sweep.
public enum BulkRunStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case running
    case paused
    case completed
    case failed
    case cancelled

    public var isActive: Bool { self == .running || self == .paused }
    public var isTerminal: Bool { !isActive }
}

/// Auth and quota failures halt without retries; consecutiveFailures trips after
/// the configured number of failed units in a row.
public enum BulkRunHaltReason: String, Codable, Sendable, Equatable, CaseIterable {
    case auth
    case quota
    case consecutiveFailures
}

/// modelId is kickoff metadata; per-annotation provenance comes from the dispatcher.
/// haltReason is set only for failed runs; completedAt exactly for terminal runs.
/// Persist overwriteExisting across resumes: false skips annotated targets, true replaces them.
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
