import Foundation
import GRDB

/// Persistence boundary for `SettingRecord`. Values are opaque strings;
/// each setting decides its own encoding (JSON for structured payloads,
/// plain string for scalars).
public protocol SettingRepository: Sendable {
    /// The string value stored at `key`, or nil if no row exists.
    func get(_ key: String) async throws -> String?
    /// Insert or update.
    func set(_ key: String, value: String) async throws
    /// Remove the row at `key`. No-op when missing.
    func delete(_ key: String) async throws
    /// Every setting as a key→value map. Useful for one-shot snapshots
    /// (e.g. exporting all settings).
    func all() async throws -> [String: String]
}

/// GRDB-backed `SettingRepository`.
public struct GRDBSettingRepository: SettingRepository {
    private let queue: DatabaseQueue

    public init(database: ChatDatabase) {
        self.queue = database.queue
    }

    public func get(_ key: String) async throws -> String? {
        try await queue.read { db in
            try SettingRecord.fetchOne(db, key: key)?.value
        }
    }

    public func set(_ key: String, value: String) async throws {
        try await queue.write { db in
            try SettingRecord(key: key, value: value).save(db)
        }
    }

    public func delete(_ key: String) async throws {
        _ = try await queue.write { db in
            try SettingRecord.deleteOne(db, key: key)
        }
    }

    public func all() async throws -> [String: String] {
        try await queue.read { db in
            let rows = try SettingRecord.fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0.value) })
        }
    }
}
