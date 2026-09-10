import Core
import Foundation
import GRDB

public enum ModelConfigurationRepositoryError: Error, Sendable, Equatable {
    case unknownModel(id: String)
    /// An update's original credential reference no longer matches, or its row was deleted.
    case staleModel(id: String)
    /// Unused keys remain durably tracked for cleanup on a subsequent launch.
    case stagedKeyCleanupFailed
    /// Reject before demoting the current selection if the kind has no compiled adapter.
    case unselectableKind(id: String, kind: String)
}

/// Owns model rows and their Keychain references.
public protocol ModelConfigurationRepository: Sendable {
    /// Known kinds only, ordered by createdAt ascending.
    func all() async throws -> [ModelConfigurationRecord]
    func fetch(id: String) async throws -> ModelConfigurationRecord?
    /// Selected row whose kind has a compiled provider adapter; runtime availability is separate.
    func selected() async throws -> ModelConfigurationRecord?
    /// Insert or update, atomically releasing the committed key's staging marker.
    /// Does not touch Keychain; register a fresh reference before writing its secret.
    func save(_ record: ModelConfigurationRecord) async throws
    /// Update an existing row only if its credential reference still matches the caller's snapshot.
    /// Comparison and persistence are atomic; a stale edit cannot restore a retired reference or deleted row.
    func update(_ record: ModelConfigurationRecord, expectedAPIKeyRef: String?) async throws
    /// Inside one write transaction, call make only when no buildable model exists.
    /// Return nil otherwise, without consuming a new ID.
    func insertIfEmpty(
        make: @Sendable () -> ModelConfigurationRecord
    ) async throws -> ModelConfigurationRecord?
    /// Delete the secret before the row so a Keychain failure leaves a retryable reference.
    /// Safe when the secret is already absent.
    func delete(id: String) async throws
    /// Atomically select after validating existence and buildability, preserving the prior selection on rejection.
    func setSelected(id: String) async throws
    func storeAPIKey(_ key: String, ref: String) async throws
    func loadAPIKey(ref: String) async throws -> String?
    /// Remove only the referenced secret, preserving the model row during a failed edit rollback.
    func deleteAPIKey(ref: String) async throws
    /// Remove a retired secret only when no persisted model, including unknown kinds, references it.
    func deleteAPIKeyIfUnreferenced(ref: String) async throws
    /// Durably records a fresh reference before any secret is written; never changes a model row.
    func registerStagedAPIKey(ref: String) async throws
    /// Deletes only this unused key and then its ledger row; referenced keys retain their secret.
    func discardStagedAPIKey(ref: String) async throws
}

public struct GRDBModelConfigurationRepository: ModelConfigurationRepository {
    private let queue: DatabaseQueue
    private let keychain: any KeychainClient
    /// Buildability means a compiled adapter, independent of runtime availability.
    /// Injectable to exercise known but unbuildable kinds.
    private let isKindBuildable: @Sendable (LLMProviderKind) -> Bool
    private let buildableKindRawValues: [String]

    public init(
        database: ChatDatabase,
        keychain: any KeychainClient,
        isKindBuildable: @escaping @Sendable (LLMProviderKind) -> Bool = { $0.hasProviderAdapter }
    ) {
        self.queue = database.queue
        self.keychain = keychain
        self.isKindBuildable = isKindBuildable
        self.buildableKindRawValues = LLMProviderKind.allCases.filter(isKindBuildable).map(\.rawValue)
    }

    public func all() async throws -> [ModelConfigurationRecord] {
        try await queue.read { db in
            try Self.knownKindRequest
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    public func fetch(id: String) async throws -> ModelConfigurationRecord? {
        try await queue.read { db in
            try Self.knownKindRequest
                .filter(Column("id") == id)
                .fetchOne(db)
        }
    }

    public func selected() async throws -> ModelConfigurationRecord? {
        try await queue.read { db in
            try buildableKindRequest
                .filter(Column("isSelected") == true)
                .fetchOne(db)
        }
    }

    /// Exclude unknown kinds before decoding, including DEBUG rows opened by a Release build.
    /// Keep their stored rows intact for binaries that recognize them.
    private static let knownKindRawValues: [String] =
        LLMProviderKind.allCases.map(\.rawValue)

    private static var knownKindRequest: QueryInterfaceRequest<ModelConfigurationRecord> {
        ModelConfigurationRecord.filter(knownKindRawValues.contains(Column("kind")))
    }

    /// Keep known but unbuildable rows editable through all/fetch, excluding them from selection and seeding.
    private var buildableKindRequest: QueryInterfaceRequest<ModelConfigurationRecord> {
        ModelConfigurationRecord.filter(buildableKindRawValues.contains(Column("kind")))
    }

    public func save(_ record: ModelConfigurationRecord) async throws {
        try await queue.write { db in
            try record.save(db)
            if let ref = record.apiKeyRef { try ModelStagedKeyRecord.deleteOne(db, key: ref) }
        }
    }

    public func update(_ record: ModelConfigurationRecord, expectedAPIKeyRef: String?) async throws {
        try await queue.write { db in
            let matches = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM modelConfiguration WHERE id = ? AND apiKeyRef IS ?)",
                arguments: [record.id, expectedAPIKeyRef]
            ) ?? false
            guard matches else { throw ModelConfigurationRepositoryError.staleModel(id: record.id) }
            // Update rather than upsert: a concurrent deletion must never resurrect its model.
            try record.update(db)
            if let previous = expectedAPIKeyRef, previous != record.apiKeyRef {
                // Ownership of the retired secret survives termination immediately after commit.
                try ModelStagedKeyRecord(id: previous).save(db)
            }
            if let ref = record.apiKeyRef { try ModelStagedKeyRecord.deleteOne(db, key: ref) }
        }
    }

    public func insertIfEmpty(
        make: @Sendable () -> ModelConfigurationRecord
    ) async throws -> ModelConfigurationRecord? {
        try await queue.write { db in
            let count = try buildableKindRequest.fetchCount(db)
            guard count == 0 else { return nil }
            let record = make()
            if record.isSelected {
                try demoteUnselectableSelections(db: db)
            }
            try record.insert(db)
            return record
        }
    }

    /// The unique index covers unknown and unbuildable kinds too; release their
    /// selection slot before inserting a selected row this binary can use.
    private func demoteUnselectableSelections(db: Database) throws {
        try ModelConfigurationRecord
            .filter(!buildableKindRawValues.contains(Column("kind")))
            .filter(Column("isSelected") == true)
            .updateAll(db, Column("isSelected").set(to: false))
    }

    public func delete(id: String) async throws {
        // Raw SQL bypasses the known-kind read filter so hidden legacy rows remain deletable.
        let probe: (exists: Bool, apiKeyRef: String?) = try await queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT apiKeyRef FROM modelConfiguration WHERE id = ?",
                arguments: [id]
            )
            return row.map { (true, $0["apiKeyRef"] as String?) } ?? (false, nil)
        }
        guard probe.exists else { return }
        if let ref = probe.apiKeyRef {
            try await keychain.delete(ref: ref)
        }
        _ = try await queue.write { db in
            try ModelConfigurationRecord.deleteOne(db, key: id)
        }
    }

    public func setSelected(id: String) async throws {
        try await queue.write { db in
            guard let record = try ModelConfigurationRecord.fetchOne(db, key: id) else {
                throw ModelConfigurationRepositoryError.unknownModel(id: id)
            }
            // Validate before demoting, or a rejected selection erases the active model.
            guard isKindBuildable(record.kind) else {
                throw ModelConfigurationRepositoryError.unselectableKind(
                    id: id, kind: record.kind.rawValue
                )
            }
            try ModelConfigurationRecord
                .filter(Column("isSelected") == true)
                .updateAll(db, Column("isSelected").set(to: false))
            try ModelConfigurationRecord
                .filter(Column("id") == id)
                .updateAll(db, Column("isSelected").set(to: true))
        }
    }

    public func storeAPIKey(_ key: String, ref: String) async throws {
        try await keychain.setString(key, ref: ref)
    }

    public func loadAPIKey(ref: String) async throws -> String? {
        try await keychain.getString(ref: ref)
    }

    public func deleteAPIKey(ref: String) async throws {
        try await keychain.delete(ref: ref)
    }

    public func deleteAPIKeyIfUnreferenced(ref: String) async throws {
        // Do not use all(): its known-kind filter omits rows written by a newer app version.
        let isReferenced = try await queue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM modelConfiguration WHERE apiKeyRef = ?)",
                arguments: [ref]
            ) ?? true
        }
        guard !isReferenced else { return }
        try await keychain.delete(ref: ref)
    }

    public func registerStagedAPIKey(ref: String) async throws {
        try await queue.write { db in try ModelStagedKeyRecord(id: ref).insert(db) }
    }

    public func discardStagedAPIKey(ref: String) async throws {
        try await deleteAPIKeyIfUnreferenced(ref: ref)
        // A failed metadata deletion remains retryable even when its secret is already absent.
        _ = try await queue.write { db in try ModelStagedKeyRecord.deleteOne(db, key: ref) }
    }

    /// Recovers abandoned keys before any model editing is available. Never call during a live app session.
    /// Individual failures retain their ledger row and do not prevent attempts for the remaining references.
    public func recoverStagedAPIKeysAtStartup() async throws {
        let refs = try await queue.read { db in
            try ModelStagedKeyRecord.order(Column("id")).fetchAll(db).map(\.id)
        }
        var failed = false
        for ref in refs {
            do { try await discardStagedAPIKey(ref: ref) } catch { failed = true }
        }
        if failed { throw ModelConfigurationRepositoryError.stagedKeyCleanupFailed }
    }

    #if DEBUG
    /// Insert each debug row once, checking its ID and calling make inside the transaction.
    /// Pass true to make only when selectable is true and no buildable row is selected; pass false otherwise.
    /// Return nil if the ID already exists.
    public func insertDebugRowIfMissing(
        id: String,
        selectable: Bool,
        make: @Sendable (_ shouldSelect: Bool) -> ModelConfigurationRecord
    ) async throws -> ModelConfigurationRecord? {
        try await queue.write { db in
            let alreadyPresent = try ModelConfigurationRecord
                .filter(Column("id") == id)
                .fetchCount(db) > 0
            guard !alreadyPresent else { return nil }
            let hasBuildableSelected = try buildableKindRequest
                .filter(Column("isSelected") == true)
                .fetchCount(db) > 0
            let shouldSelect = selectable && !hasBuildableSelected
            if shouldSelect {
                try demoteUnselectableSelections(db: db)
            }
            let record = make(shouldSelect)
            try record.insert(db)
            return record
        }
    }
    #endif
}
