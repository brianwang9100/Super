import Core
import Foundation
import GRDB

public struct MemoryRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "memory"

    public var id: String
    public var text: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, text: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(entry: MemoryEntry) {
        self.id = entry.id
        self.text = entry.text
        self.createdAt = entry.createdAt
        self.updatedAt = entry.updatedAt
    }

    public var entry: MemoryEntry {
        MemoryEntry(id: id, text: text, createdAt: createdAt, updatedAt: updatedAt)
    }
}
