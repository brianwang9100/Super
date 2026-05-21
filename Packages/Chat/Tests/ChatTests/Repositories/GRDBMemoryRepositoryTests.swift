import Core
import Foundation
import Testing
@testable import Chat

/// Tests for `GRDBMemoryRepository` — round-trip, createdAt ordering,
/// capacity / length / emptiness guards, and clear-all.
@Suite("GRDBMemoryRepository")
struct GRDBMemoryRepositoryTests {

    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> (ChatDatabase, GRDBMemoryRepository) {
        let db = try ChatDatabase.makeInMemory()
        return (db, GRDBMemoryRepository(database: db))
    }

    private func makeEntry(id: String, text: String, offset: TimeInterval) -> MemoryEntry {
        let date = baseDate.addingTimeInterval(offset)
        return MemoryEntry(id: id, text: text, createdAt: date, updatedAt: date)
    }

    @Test func allReturnsEmptyOnFreshDatabase() async throws {
        let (_, store) = try makeStore()
        #expect(try await store.all().isEmpty)
    }

    @Test func saveAndFetchRoundTrip() async throws {
        let (_, store) = try makeStore()
        let entry = makeEntry(id: "m1", text: "Prefers metric units.", offset: 0)
        try await store.save(entry)

        let fetched = try await store.fetch(id: "m1")
        #expect(fetched == entry)
    }

    @Test func allReturnsOldestFirst() async throws {
        let (_, store) = try makeStore()
        // Insert out of order so the ordering can't fall back on insertion
        // order or rowid — the index must do the work.
        try await store.save(makeEntry(id: "m2", text: "Likes terse responses.", offset: 10))
        try await store.save(makeEntry(id: "m1", text: "Vegetarian.", offset: 0))
        try await store.save(makeEntry(id: "m3", text: "Lives in Tokyo.", offset: 20))

        let ids = try await store.all().map(\.id)
        #expect(ids == ["m1", "m2", "m3"])
    }

    @Test func updateRewritesTextAndTimestamp() async throws {
        let (_, store) = try makeStore()
        try await store.save(makeEntry(id: "m1", text: "Prefers metric.", offset: 0))

        let newDate = baseDate.addingTimeInterval(60)
        try await store.update(id: "m1", text: "Prefers SI units.", updatedAt: newDate)

        let fetched = try await store.fetch(id: "m1")
        #expect(fetched?.text == "Prefers SI units.")
        #expect(fetched?.updatedAt == newDate)
        // createdAt must not change on update — that would silently re-sort
        // the system-prompt block and shuffle "what I remember about you".
        #expect(fetched?.createdAt == baseDate)
    }

    @Test func updateThrowsWhenIdMissing() async throws {
        let (_, store) = try makeStore()
        do {
            try await store.update(id: "missing", text: "x", updatedAt: baseDate)
            Issue.record("expected MemoryRepositoryError.notFound")
        } catch let error as MemoryRepositoryError {
            #expect(error == .notFound(id: "missing"))
        }
    }

    @Test func deleteRemovesOneRow() async throws {
        let (_, store) = try makeStore()
        try await store.save(makeEntry(id: "m1", text: "A", offset: 0))
        try await store.save(makeEntry(id: "m2", text: "B", offset: 1))

        try await store.delete(id: "m1")

        let remaining = try await store.all().map(\.id)
        #expect(remaining == ["m2"])
    }

    @Test func deleteIsNoOpForUnknownId() async throws {
        let (_, store) = try makeStore()
        try await store.delete(id: "nope")
        #expect(try await store.all().isEmpty)
    }

    @Test func clearAllRemovesEverything() async throws {
        let (_, store) = try makeStore()
        for i in 0..<5 {
            try await store.save(makeEntry(id: "m\(i)", text: "fact \(i)", offset: TimeInterval(i)))
        }
        try await store.clearAll()
        #expect(try await store.all().isEmpty)
    }

    @Test func saveRejectsEmptyText() async throws {
        let (_, store) = try makeStore()
        do {
            try await store.save(makeEntry(id: "m1", text: "   ", offset: 0))
            Issue.record("expected MemoryRepositoryError.emptyText")
        } catch let error as MemoryRepositoryError {
            #expect(error == .emptyText)
        }
    }

    @Test func saveRejectsOverlongText() async throws {
        let (_, store) = try makeStore()
        let tooLong = String(repeating: "a", count: MemoryLimits.maxTextLength + 1)
        do {
            try await store.save(makeEntry(id: "m1", text: tooLong, offset: 0))
            Issue.record("expected MemoryRepositoryError.textTooLong")
        } catch let error as MemoryRepositoryError {
            #expect(error == .textTooLong(limit: MemoryLimits.maxTextLength))
        }
    }

    @Test func saveRejectsAtCapacity() async throws {
        let (_, store) = try makeStore()
        for i in 0..<MemoryLimits.maxEntries {
            try await store.save(makeEntry(id: "m\(i)", text: "fact \(i)", offset: TimeInterval(i)))
        }
        do {
            try await store.save(makeEntry(
                id: "overflow",
                text: "one too many",
                offset: TimeInterval(MemoryLimits.maxEntries)
            ))
            Issue.record("expected MemoryRepositoryError.overCapacity")
        } catch let error as MemoryRepositoryError {
            #expect(error == .overCapacity(limit: MemoryLimits.maxEntries))
        }
    }
}
