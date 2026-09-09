import Foundation

public protocol MemoryRepository: Sendable {
    /// Oldest first for stable prompt ordering across turns.
    func all() async throws -> [MemoryEntry]

    func fetch(id: String) async throws -> MemoryEntry?

    /// Throws overCapacity at maxEntries, textTooLong beyond maxTextLength, or emptyText for blank input.
    func save(_ entry: MemoryEntry) async throws

    /// Updates text/timestamp; throws notFound or the same text validation errors as save.
    func update(id: String, text: String, updatedAt: Date) async throws

    /// No-op for a missing ID.
    func delete(id: String) async throws

    /// Atomically deletes and returns the prior row, or nil. Separate fetch/delete
    /// would race Settings edits and report stale text in the tool artifact.
    func fetchAndDelete(id: String) async throws -> MemoryEntry?

    func clearAll() async throws
}

public struct MemoryEntry: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let text: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: String, text: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Conformers reject excess input explicitly; silent truncation would lose preferences.
public enum MemoryLimits {
    public static let maxEntries: Int = 100
    /// Maximum Swift characters per memory.
    public static let maxTextLength: Int = 500
}

public enum MemoryRepositoryError: Error, Sendable, Equatable {
    case overCapacity(limit: Int)
    case textTooLong(limit: Int)
    case emptyText
    case notFound(id: String)
}
