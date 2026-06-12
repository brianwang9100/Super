import Core
import Foundation
import GRDB
import Testing
@testable import Bible

/// Integration tests for `GRDBBibleBookmarkRepository` against an in-memory
/// database — the single `toggle` covers assign, unassign, move-across-
/// chapters, and replace-on-chapter, and the two UNIQUE indexes hold the
/// 1:1 invariants in both directions.
@Suite("GRDBBibleBookmarkRepository")
struct BibleBookmarkRepositoryTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let later = Date(timeIntervalSince1970: 1_700_000_600)

    private func makeFixture() throws -> (GRDBBibleBookmarkRepository, BibleDatabase) {
        let database = try BibleDatabase.makeInMemory()
        let ids = DeterministicIDGenerator(prefix: "bm")
        return (GRDBBibleBookmarkRepository(database: database, ids: ids), database)
    }

    @Test("toggling an unassigned colour bookmarks the chapter")
    func toggleAssigns() async throws {
        let (repository, _) = try makeFixture()
        try await repository.toggle(color: .clay, bookId: "JHN", chapterNumber: 3, at: now)
        let rows = try await repository.allBookmarks()
        #expect(rows.count == 1)
        #expect(rows.first?.color == .clay)
        #expect(rows.first?.bookId == "JHN")
        #expect(rows.first?.chapterNumber == 3)
        #expect(rows.first?.createdAt == now)
    }

    @Test("toggling the chapter's own colour removes the bookmark")
    func toggleUnassigns() async throws {
        let (repository, _) = try makeFixture()
        try await repository.toggle(color: .clay, bookId: "JHN", chapterNumber: 3, at: now)
        try await repository.toggle(color: .clay, bookId: "JHN", chapterNumber: 3, at: later)
        let rows = try await repository.allBookmarks()
        #expect(rows.isEmpty)
    }

    @Test("a removed colour is free to assign again")
    func removedColourIsReassignable() async throws {
        let (repository, _) = try makeFixture()
        try await repository.toggle(color: .clay, bookId: "JHN", chapterNumber: 3, at: now)
        try await repository.toggle(color: .clay, bookId: "JHN", chapterNumber: 3, at: later)
        try await repository.toggle(color: .clay, bookId: "ROM", chapterNumber: 8, at: later)
        let rows = try await repository.allBookmarks()
        #expect(rows.count == 1)
        #expect(rows.first?.bookId == "ROM")
        #expect(rows.first?.chapterNumber == 8)
    }

    @Test("toggling a colour assigned elsewhere moves it to the new chapter")
    func toggleMovesAcrossChapters() async throws {
        let (repository, _) = try makeFixture()
        try await repository.toggle(color: .gold, bookId: "JHN", chapterNumber: 3, at: now)
        try await repository.toggle(color: .gold, bookId: "ROM", chapterNumber: 8, at: later)
        let rows = try await repository.allBookmarks()
        #expect(rows.count == 1)
        #expect(rows.first?.color == .gold)
        #expect(rows.first?.bookId == "ROM")
        #expect(rows.first?.chapterNumber == 8)
    }

    @Test("assigning a second colour to a chapter frees the first colour")
    func toggleReplacesChapterColour() async throws {
        let (repository, _) = try makeFixture()
        try await repository.toggle(color: .clay, bookId: "JHN", chapterNumber: 3, at: now)
        try await repository.toggle(color: .gold, bookId: "JHN", chapterNumber: 3, at: later)
        let rows = try await repository.allBookmarks()
        #expect(rows.count == 1)
        #expect(rows.first?.color == .gold)
        // …and clay is free to land on another chapter without conflict.
        try await repository.toggle(color: .clay, bookId: "ROM", chapterNumber: 8, at: later)
        let after = try await repository.allBookmarks()
        #expect(after.count == 2)
    }

    @Test("an arbitrary toggle sequence never violates the 1:1 invariants")
    func toggleSequenceHoldsInvariants() async throws {
        let (repository, _) = try makeFixture()
        try await repository.toggle(color: .clay, bookId: "JHN", chapterNumber: 3, at: now)
        try await repository.toggle(color: .gold, bookId: "JHN", chapterNumber: 3, at: now)
        try await repository.toggle(color: .gold, bookId: "ROM", chapterNumber: 8, at: now)
        try await repository.toggle(color: .moss, bookId: "PSA", chapterNumber: 23, at: now)
        try await repository.toggle(color: .moss, bookId: "PSA", chapterNumber: 23, at: later)
        try await repository.toggle(color: .plum, bookId: "JHN", chapterNumber: 3, at: later)
        let rows = try await repository.allBookmarks()
        let colors = rows.map(\.colorId)
        let chapters = rows.map { "\($0.bookId)/\($0.chapterNumber)" }
        #expect(Set(colors).count == colors.count, "one chapter per colour")
        #expect(Set(chapters).count == chapters.count, "one colour per chapter")
        #expect(Set(chapters) == ["JHN/3", "ROM/8"])
    }

    @Test("the schema rejects a direct duplicate colour row")
    func duplicateColourInsertThrows() async throws {
        let (_, database) = try makeFixture()
        let record = BibleBookmarkRecord(
            id: "bm-a", colorId: "clay", bookId: "JHN", chapterNumber: 3,
            createdAt: now
        )
        let duplicateColor = BibleBookmarkRecord(
            id: "bm-b", colorId: "clay", bookId: "ROM", chapterNumber: 8,
            createdAt: now
        )
        try await database.queue.write { db in try record.insert(db) }
        await #expect(throws: DatabaseError.self) {
            try await database.queue.write { db in try duplicateColor.insert(db) }
        }
    }

    @Test("the schema rejects a direct duplicate chapter row")
    func duplicateChapterInsertThrows() async throws {
        let (_, database) = try makeFixture()
        let record = BibleBookmarkRecord(
            id: "bm-a", colorId: "clay", bookId: "JHN", chapterNumber: 3,
            createdAt: now
        )
        let duplicateChapter = BibleBookmarkRecord(
            id: "bm-b", colorId: "gold", bookId: "JHN", chapterNumber: 3,
            createdAt: now
        )
        try await database.queue.write { db in try record.insert(db) }
        await #expect(throws: DatabaseError.self) {
            try await database.queue.write { db in try duplicateChapter.insert(db) }
        }
    }
}
