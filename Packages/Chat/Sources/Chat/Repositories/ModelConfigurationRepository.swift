import Core
import Foundation
import GRDB

/// Errors thrown by `ModelConfigurationRepository` operations.
public enum ModelConfigurationRepositoryError: Error, Sendable, Equatable {
    /// `setSelected(id:)` referenced a row that doesn't exist.
    case unknownModel(id: String)
}

/// Persistence boundary for `ModelConfigurationRecord` plus the matching
/// Keychain entry that holds the row's API (Application Programming
/// Interface) key. The repository owns both halves so callers don't have
/// to wire `KeychainClient` separately at every call site.
public protocol ModelConfigurationRepository: Sendable {
    /// Every configured model, ordered by `createdAt` ascending so the UI
    /// shows them in setup order.
    func all() async throws -> [ModelConfigurationRecord]
    /// One row by id, ignoring selection state.
    func fetch(id: String) async throws -> ModelConfigurationRecord?
    /// The currently selected model, if any.
    func selected() async throws -> ModelConfigurationRecord?
    /// Insert or update. Does **not** touch the Keychain — pair with
    /// `storeAPIKey(_:ref:)` when persisting a freshly entered key.
    func save(_ record: ModelConfigurationRecord) async throws
    /// Delete the row and the matching Keychain entry referenced by its
    /// `apiKeyRef`. The Keychain delete runs first: a Keychain failure
    /// leaves the DB row in place so the caller can retry, instead of
    /// orphaning a secret that no row points at. Safe to call when no
    /// Keychain entry exists.
    func delete(id: String) async throws
    /// Mark `id` as the unique selected row, clearing any prior selection
    /// in the same write transaction.
    /// - Throws: `ModelConfigurationRepositoryError.unknownModel` when no
    ///   row matches `id`.
    func setSelected(id: String) async throws
    /// Persist the plaintext key under `ref` in the Keychain.
    func storeAPIKey(_ key: String, ref: String) async throws
    /// Read the plaintext key back out, or nil if no entry exists.
    func loadAPIKey(ref: String) async throws -> String?
}

/// GRDB-backed `ModelConfigurationRepository`. The selected-exclusive
/// invariant is enforced at the schema level by a partial unique index on
/// `modelConfiguration(isSelected) WHERE isSelected = 1`, so any caller
/// (including `save(_:)`) that tries to land a second selected row hits a
/// SQLite (Structured Query Language) UNIQUE violation. `setSelected(id:)`
/// is the safe path: it demotes the prior selected row in the same write
/// transaction so the index never sees the conflict.
public struct GRDBModelConfigurationRepository: ModelConfigurationRepository {
    private let queue: DatabaseQueue
    private let keychain: any KeychainClient

    public init(database: ChatDatabase, keychain: any KeychainClient) {
        self.queue = database.queue
        self.keychain = keychain
    }

    public func all() async throws -> [ModelConfigurationRecord] {
        try await queue.read { db in
            try ModelConfigurationRecord
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    public func fetch(id: String) async throws -> ModelConfigurationRecord? {
        try await queue.read { db in
            try ModelConfigurationRecord.fetchOne(db, key: id)
        }
    }

    public func selected() async throws -> ModelConfigurationRecord? {
        try await queue.read { db in
            try ModelConfigurationRecord
                .filter(Column("isSelected") == true)
                .fetchOne(db)
        }
    }

    public func save(_ record: ModelConfigurationRecord) async throws {
        try await queue.write { db in
            try record.save(db)
        }
    }

    public func delete(id: String) async throws {
        guard let existing = try await fetch(id: id) else { return }
        // Keychain first: if it throws, the DB row remains and the user
        // can retry instead of orphaning the secret. Skip when the row
        // has no `apiKeyRef` (on-device kinds like `.appleFoundation`
        // never write to the Keychain).
        if let ref = existing.apiKeyRef {
            try await keychain.delete(ref: ref)
        }
        _ = try await queue.write { db in
            try ModelConfigurationRecord.deleteOne(db, key: id)
        }
    }

    public func setSelected(id: String) async throws {
        try await queue.write { db in
            guard try ModelConfigurationRecord.fetchOne(db, key: id) != nil else {
                throw ModelConfigurationRepositoryError.unknownModel(id: id)
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
}
