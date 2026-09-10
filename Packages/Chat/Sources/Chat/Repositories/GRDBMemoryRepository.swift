import Core
import Foundation
import GRDB

public struct GRDBMemoryRepository: MemoryRepository {
    private let queue: DatabaseQueue

    public init(database: ChatDatabase) {
        self.queue = database.queue
    }

    public func all() async throws -> [MemoryEntry] {
        try await queue.read { db in
            try MemoryRecord
                .order(Column("createdAt"))
                .fetchAll(db)
                .map(\.entry)
        }
    }

    public func fetch(id: String) async throws -> MemoryEntry? {
        try await queue.read { db in
            try MemoryRecord.fetchOne(db, key: id)?.entry
        }
    }

    public func save(_ entry: MemoryEntry) async throws {
        try validate(text: entry.text)
        try await queue.write { db in
            // Check capacity inside the write transaction so concurrent saves cannot overfill it.
            let count = try MemoryRecord.fetchCount(db)
            if count >= MemoryLimits.maxEntries {
                throw MemoryRepositoryError.overCapacity(limit: MemoryLimits.maxEntries)
            }
            try MemoryRecord(entry: entry).insert(db)
        }
    }

    public func update(id: String, text: String, updatedAt: Date) async throws {
        try validate(text: text)
        try await queue.write { db in
            guard var record = try MemoryRecord.fetchOne(db, key: id) else {
                throw MemoryRepositoryError.notFound(id: id)
            }
            record.text = text
            record.updatedAt = updatedAt
            try record.update(db)
        }
    }

    public func delete(id: String) async throws {
        _ = try await queue.write { db in
            try MemoryRecord.deleteOne(db, key: id)
        }
    }

    public func fetchAndDelete(id: String) async throws -> MemoryEntry? {
        // Read and delete atomically so the returned entry matches what was removed.
        try await queue.write { db in
            guard let record = try MemoryRecord.fetchOne(db, key: id) else {
                return nil
            }
            try record.delete(db)
            return record.entry
        }
    }

    public func clearAll() async throws {
        _ = try await queue.write { db in
            try MemoryRecord.deleteAll(db)
        }
    }

    private func validate(text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw MemoryRepositoryError.emptyText
        }
        if trimmed.count > MemoryLimits.maxTextLength {
            throw MemoryRepositoryError.textTooLong(limit: MemoryLimits.maxTextLength)
        }
    }
}
