import Core
import Foundation
import GRDB
import Testing
@testable import Bible

/// Tests for `ChapterHighlightsRequest` — the GRDBQuery request the chapter
/// renderer's `@Query` observes. The `fetch` body must scope to one chapter,
/// drop cleared highlights, and verse-order the result.
@Suite("ChapterHighlightsRequest")
struct ChapterHighlightsRequestTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRepository() throws -> (GRDBBibleHighlightRepository, BibleDatabase) {
        let database = try BibleDatabase.makeInMemory()
        return (
            GRDBBibleHighlightRepository(database: database, ids: DeterministicIDGenerator()),
            database
        )
    }

    private func fetch(
        _ database: BibleDatabase, bookId: String, chapterNumber: Int
    ) throws -> [BibleHighlightRecord] {
        try database.queue.read { db in
            try ChapterHighlightsRequest(bookId: bookId, chapterNumber: chapterNumber).fetch(db)
        }
    }

    @Test("the request returns only the asked-for chapter's active highlights")
    func scopesToChapter() async throws {
        let (repository, database) = try makeRepository()
        try await repository.setHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 9, color: .yellow, at: now
        )
        // A different chapter and a different book must not leak in.
        try await repository.setHighlight(
            bookId: "1PE", chapterNumber: 3, verseNumber: 1, color: .green, at: now
        )
        try await repository.setHighlight(
            bookId: "ROM", chapterNumber: 2, verseNumber: 9, color: .blue, at: now
        )
        let rows = try fetch(database, bookId: "1PE", chapterNumber: 2)
        #expect(rows.map(\.verseNumber) == [9])
        #expect(rows.first?.color == .yellow)
    }

    @Test("the request excludes cleared highlights")
    func excludesCleared() async throws {
        let (repository, database) = try makeRepository()
        try await repository.setHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 4, color: .yellow, at: now
        )
        try await repository.setHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 9, color: .green, at: now
        )
        try await repository.clearHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 4, at: now
        )
        let rows = try fetch(database, bookId: "1PE", chapterNumber: 2)
        #expect(rows.map(\.verseNumber) == [9])
    }

    @Test("the request orders highlights by verse number")
    func ordersByVerse() async throws {
        let (repository, database) = try makeRepository()
        for verse in [11, 4, 9] {
            try await repository.setHighlight(
                bookId: "1PE", chapterNumber: 2, verseNumber: verse, color: .pink, at: now
            )
        }
        let rows = try fetch(database, bookId: "1PE", chapterNumber: 2)
        #expect(rows.map(\.verseNumber) == [4, 9, 11])
    }
}
