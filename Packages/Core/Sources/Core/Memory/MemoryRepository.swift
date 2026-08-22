import Foundation

/// Persistence boundary for the Chat applet's user-preference memory.
///
/// One row per memory; the LLM (Large Language Model) writes via the
/// `memory` tool and the user curates via the Settings memory pane. Sorted
/// `createdAt` ascending so the system-prompt block keeps stable order
/// across turns — a reorder on every fetch would flicker the model's
/// view of "what I remember about you" without buying anything.
///
/// Chat ships a GRDB-backed conformer (`GRDBMemoryRepository`); tests
/// substitute an in-memory one. Core stays GRDB-free per its AGENTS.md.
public protocol MemoryRepository: Sendable {
    /// All memories, oldest first.
    func all() async throws -> [MemoryEntry]

    /// Fetch one memory by id, or nil if it's been deleted.
    func fetch(id: String) async throws -> MemoryEntry?

    /// Insert a new memory. Throws ``MemoryRepositoryError/overCapacity``
    /// when the table is already at ``MemoryLimits/maxEntries`` and
    /// ``MemoryRepositoryError/textTooLong`` when `text` exceeds
    /// ``MemoryLimits/maxTextLength``. Empty / whitespace-only text
    /// throws ``MemoryRepositoryError/emptyText``.
    func save(_ entry: MemoryEntry) async throws

    /// Replace the text + updatedAt of an existing memory. Throws
    /// ``MemoryRepositoryError/notFound`` when no row matches `id`, same
    /// length / emptiness errors as `save`.
    func update(id: String, text: String, updatedAt: Date) async throws

    /// Delete one memory. No-op when `id` does not exist.
    func delete(id: String) async throws

    /// Atomically read a memory and delete it in one write transaction.
    /// Returns the row that was deleted, or `nil` if no row matched —
    /// in which case nothing is written.
    ///
    /// Single-call semantics matter for the `memory` tool's `forget`
    /// path: the tool needs the prior text to surface in the artifact
    /// shown under the assistant bubble, and a separate
    /// `fetch` + `delete` pair would race a concurrent Settings-pane
    /// write between the two calls, leaving the artifact carrying
    /// stale text.
    func fetchAndDelete(id: String) async throws -> MemoryEntry?

    /// Delete every memory. Used by the Settings "Clear All" affordance.
    func clearAll() async throws
}

/// One persisted user-preference memory.
///
/// Plain data; the persistence layer (GRDB in Chat, in-memory in tests)
/// stores it as a single row keyed on `id`.
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

/// Caps enforced by every `MemoryRepository` conformer.
///
/// The numbers are deliberately small — memory is a short list of stable
/// preferences, not a journal. Over-cap returns a structured error so the
/// LLM (Large Language Model) sees "I'm full" and can ask the user to
/// curate, rather than a silent drop or a 500-entry context bloat.
public enum MemoryLimits {
    /// Maximum number of memories stored at once.
    public static let maxEntries: Int = 100
    /// Maximum characters allowed in a single memory's `text`.
    public static let maxTextLength: Int = 500
}

/// Errors thrown by `MemoryRepository` writers.
public enum MemoryRepositoryError: Error, Sendable, Equatable {
    case overCapacity(limit: Int)
    case textTooLong(limit: Int)
    case emptyText
    case notFound(id: String)
}
