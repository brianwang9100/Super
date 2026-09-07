import Foundation
import GRDB

/// Persistence failures for conditional narration-setting writes.
public enum NarrationSettingsError: Error, Sendable {
    case staleDraft, missingCredential, secureStorage, persistence
}

/// Persistence boundary for narration settings, with optimistic revision checks.
public protocol NarrationSettingsRepository: Sendable {
    func load() async throws -> NarrationSettingsRecord?
    /// Commits preferences and releases staging ownership of the committed owned key atomically.
    func save(_ record: NarrationSettingsRecord, expecting revision: Int) async throws
    /// Durably records cleanup ownership before any secret is written, without changing active settings.
    func registerStagedKey(ref: String) async throws
    /// Lists provisional Keychain references that still need cleanup or commitment.
    func stagedKeyRefs() async throws -> [String]
    /// Forget a staged reference only after its secret is removed or verified as the active owned key.
    func removeStagedKey(ref: String) async throws
}

/// Bible-owned SQLite storage. Keys themselves remain exclusively in Keychain.
public struct GRDBNarrationSettingsRepository: NarrationSettingsRepository {
    private let database: BibleDatabase
    public init(database: BibleDatabase) { self.database = database }
    public func load() async throws -> NarrationSettingsRecord? {
        try await database.queue.read { try NarrationSettingsRecord.fetchOne($0) }
    }
    public func save(_ record: NarrationSettingsRecord, expecting revision: Int) async throws {
        try await database.queue.write { db in
            let existing = try NarrationSettingsRecord.fetchOne(db)
            guard (existing?.revision ?? 0) == revision else { throw NarrationSettingsError.staleDraft }
            try record.save(db)
            if record.ownsKey, let ref = record.keyRef {
                try NarrationStagedKeyRecord.deleteOne(db, key: ref)
            }
        }
    }
    /// Registers a provisional reference before its secret is written to Keychain.
    public func registerStagedKey(ref: String) async throws {
        try await database.queue.write { db in
            try NarrationStagedKeyRecord(id: ref).insert(db)
        }
    }
    /// Lists durably tracked provisional references in stable order.
    public func stagedKeyRefs() async throws -> [String] {
        try await database.queue.read { db in
            try NarrationStagedKeyRecord.order(Column("id")).fetchAll(db).map(\.id)
        }
    }
    /// Removes cleanup metadata after the secret is deleted or confirmed active.
    public func removeStagedKey(ref: String) async throws {
        _ = try await database.queue.write { db in
            try NarrationStagedKeyRecord.deleteOne(db, key: ref)
        }
    }
}
