import Core
import Foundation
import GRDB
import Testing
@testable import Bible

/// Integration tests for `GRDBBibleHighlightRepository` against an in-memory
/// database — the insert, recolour, soft-delete, and clear-then-restore
/// behaviours the one-row-per-verse highlight model relies on.
@Suite("GRDBBibleHighlightRepository")
struct BibleHighlightRepositoryTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let later = Date(timeIntervalSince1970: 1_700_000_600)
    private let evenLater = Date(timeIntervalSince1970: 1_700_001_200)

    private func makeFixture() throws -> (GRDBBibleHighlightRepository, BibleDatabase) {
        let database = try BibleDatabase.makeInMemory()
        let ids = DeterministicIDGenerator(prefix: "hl")
        return (GRDBBibleHighlightRepository(database: database, ids: ids), database)
    }

    /// Every active highlight row for `(1PE, 2)`, verse-ordered.
    private func activeHighlights(_ database: BibleDatabase) throws -> [BibleHighlightRecord] {
        try database.queue.read { db in
            try ChapterHighlightsRequest(bookId: "1PE", chapterNumber: 2).fetch(db)
        }
    }

    @Test("setting a highlight inserts a row for the verse")
    func setInsertsRow() async throws {
        let (repository, database) = try makeFixture()
        try await repository.setHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 9, color: .yellow, at: now
        )
        let rows = try activeHighlights(database)
        #expect(rows.count == 1)
        #expect(rows.first?.verseNumber == 9)
        #expect(rows.first?.color == .yellow)
        #expect(rows.first?.createdAt == now)
    }

    @Test("recolouring a verse updates its row in place rather than inserting")
    func recolourUpdatesInPlace() async throws {
        let (repository, database) = try makeFixture()
        try await repository.setHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 9, color: .yellow, at: now
        )
        try await repository.setHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 9, color: .blue, at: later
        )
        let rows = try activeHighlights(database)
        #expect(rows.count == 1)
        #expect(rows.first?.color == .blue)
        // The original row is reused: createdAt stays, updatedAt advances.
        #expect(rows.first?.createdAt == now)
        #expect(rows.first?.updatedAt == later)
    }

    @Test("clearing a highlight soft-deletes the row")
    func clearSoftDeletes() async throws {
        let (repository, database) = try makeFixture()
        try await repository.setHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 9, color: .yellow, at: now
        )
        try await repository.clearHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 9, at: later
        )
        #expect(try activeHighlights(database).isEmpty)
        // The row survives as a tombstone rather than being deleted outright.
        let allRows = try await database.queue.read { db in
            try BibleHighlightRecord.fetchAll(db)
        }
        #expect(allRows.count == 1)
        #expect(allRows.first?.deletedAt == later)
    }

    @Test("re-highlighting a cleared verse restores its original row")
    func reHighlightRestoresRow() async throws {
        let (repository, database) = try makeFixture()
        try await repository.setHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 9, color: .yellow, at: now
        )
        try await repository.clearHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 9, at: later
        )
        try await repository.setHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 9, color: .green, at: later
        )
        let rows = try activeHighlights(database)
        #expect(rows.count == 1)
        #expect(rows.first?.color == .green)
        #expect(rows.first?.deletedAt == nil)
        #expect(rows.first?.createdAt == now, "the cleared row is reused, not replaced")
        // No second row was minted for the verse.
        let total = try await database.queue.read { db in try BibleHighlightRecord.fetchCount(db) }
        #expect(total == 1)
    }

    @Test("activeHighlightColors returns only active verses' colours")
    func activeHighlightColorsOmitsClearedAndUnhighlighted() async throws {
        let (repository, _) = try makeFixture()
        try await repository.setHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 4, color: .yellow, at: now
        )
        try await repository.setHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 5, color: .green, at: now
        )
        // Verse 6 is highlighted then cleared — it must not surface.
        try await repository.setHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 6, color: .blue, at: now
        )
        try await repository.clearHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 6, at: later
        )

        // Verse 7 was never highlighted; it's queried but should be absent.
        let colors = try await repository.activeHighlightColors(
            bookId: "1PE", chapterNumber: 2, verseNumbers: [4, 5, 6, 7]
        )
        #expect(colors == [4: .yellow, 5: .green])
    }

    @Test("clearing a verse that was never highlighted is a no-op")
    func clearUnhighlightedIsNoOp() async throws {
        let (repository, database) = try makeFixture()
        try await repository.clearHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 9, at: now
        )
        let total = try await database.queue.read { db in try BibleHighlightRecord.fetchCount(db) }
        #expect(total == 0)
    }

    @Test("clearing an already-cleared highlight leaves the tombstone untouched")
    func clearAlreadyClearedIsNoOp() async throws {
        let (repository, database) = try makeFixture()
        try await repository.setHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 9, color: .yellow, at: now
        )
        try await repository.clearHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 9, at: later
        )
        // The second clear must not re-stamp deletedAt or advance updatedAt —
        // the guard bails on a row that is already soft-deleted.
        try await repository.clearHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 9, at: evenLater
        )
        let rows = try await database.queue.read { db in try BibleHighlightRecord.fetchAll(db) }
        #expect(rows.count == 1)
        #expect(rows.first?.deletedAt == later)
        #expect(rows.first?.updatedAt == later)
    }
}
