import Foundation
import GRDB

public protocol SettingRepository: Sendable {
    func get(_ key: String) async throws -> String?
    func set(_ key: String, value: String) async throws
    /// No-op if missing.
    func delete(_ key: String) async throws
    func all() async throws -> [String: String]
}

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
