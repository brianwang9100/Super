import Foundation
import GRDB

/// Persistence failures for conditional narration-setting writes.
public enum NarrationSettingsError: Error, Sendable {
    case staleDraft, missingCredential, secureStorage, persistence
}

/// Persistence boundary for narration settings, with optimistic revision checks.
public protocol NarrationSettingsRepository: Sendable {
    func load() async throws -> NarrationSettingsRecord?
    func save(_ record: NarrationSettingsRecord, expecting revision: Int) async throws
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
        }
    }
}
