import Core
import Foundation
import GRDB

/// GRDB-backed conformer for Core's `MemoryRepository`. Lives in Chat
/// because Chat owns the database; Core stays GRDB-free.
///
/// Writes enforce ``MemoryLimits`` so a hostile model that loops on
/// `save` (or a user paste of 50KB of "remember this") can't fill the
/// prompt indefinitely.
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
            // Capacity check runs inside the write transaction so two
            // racing `save`s can't both observe `count < max` and then
            // both insert.
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
        // Both the read and the delete share one write transaction so a
        // concurrent `update`/`delete` from the Settings pane can't slip
        // in between and stale the returned entry.
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
        // Measure the trimmed length, not the raw length: a 500-char
        // memory with a trailing newline (the LLM occasionally appends
        // one) would otherwise be rejected even though its meaningful
        // content is at the limit. The two write paths (MemoryTool +
        // SettingsViewModel) both trim before storing, so trimmed
        // length is what actually lands in the row.
        if trimmed.count > MemoryLimits.maxTextLength {
            throw MemoryRepositoryError.textTooLong(limit: MemoryLimits.maxTextLength)
        }
    }
}
