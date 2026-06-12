import Foundation
import GRDB
import Testing
@testable import Bible

/// Tests for `BookAnnotationsExistenceRequest` — the book-picker bubble
/// visibility request returning the set of `bookId`s carrying a book-level
/// annotation (chapter- and verse-level rows don't count).
@Suite("BookAnnotationsExistenceRequest")
struct BookAnnotationsExistenceRequestTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeFixture() throws -> (GRDBBibleAnnotationRepository, BibleDatabase) {
        let database = try BibleDatabase.makeInMemory()
        return (GRDBBibleAnnotationRepository(database: database), database)
    }

    private func fetch(_ database: BibleDatabase) throws -> Set<String> {
        try database.queue.read { db in
            try BookAnnotationsExistenceRequest().fetch(db)
        }
    }

    @Test("empty database yields the empty set")
    func emptyDatabase() throws {
        let (_, database) = try makeFixture()
        #expect(try fetch(database).isEmpty)
    }

    @Test("a book-level annotation makes its book appear in the set")
    func bookLevelAnnotationCountsTheBook() async throws {
        let (repository, database) = try makeFixture()
        try await repository.replace(
            target: .book, bookId: "GEN", chapterNumber: nil, verseStart: nil, verseEnd: nil,
            inserting: [
                BibleAnnotationRecord(
                    id: "g", target: .book, bookId: "GEN",
                    summary: "In the beginning.",
                    source: .user, modelId: "m", createdAt: t0
                )
            ]
        )
        #expect(try fetch(database) == ["GEN"])
    }

    @Test("chapter- and verse-level annotations do not count the book")
    func subBookAnnotationsExcluded() async throws {
        let (repository, database) = try makeFixture()
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30,
            inserting: [
                BibleAnnotationRecord(
                    id: "a", target: .verse, bookId: "ROM",
                    chapterNumber: 8, verseStart: 28, verseEnd: 30,
                    summary: "Verse note.",
                    source: .user, modelId: "m", createdAt: t0
                )
            ]
        )
        try await repository.replace(
            target: .chapter, bookId: "JHN", chapterNumber: 3, verseStart: nil, verseEnd: nil,
            inserting: [
                BibleAnnotationRecord(
                    id: "j", target: .chapter, bookId: "JHN", chapterNumber: 3,
                    summary: "Nicodemus.",
                    source: .user, modelId: "m", createdAt: t0
                )
            ]
        )
        #expect(try fetch(database).isEmpty)
    }

    @Test("a book with only sub-book annotations stays out even when another book qualifies")
    func mixedBooksReturnOnlyBookLevel() async throws {
        let (repository, database) = try makeFixture()
        try await repository.replace(
            target: .book, bookId: "GEN", chapterNumber: nil, verseStart: nil, verseEnd: nil,
            inserting: [
                BibleAnnotationRecord(
                    id: "g", target: .book, bookId: "GEN",
                    summary: "In the beginning.",
                    source: .user, modelId: "m", createdAt: t0
                )
            ]
        )
        try await repository.replace(
            target: .chapter, bookId: "JHN", chapterNumber: 3, verseStart: nil, verseEnd: nil,
            inserting: [
                BibleAnnotationRecord(
                    id: "j", target: .chapter, bookId: "JHN", chapterNumber: 3,
                    summary: "Nicodemus.",
                    source: .user, modelId: "m", createdAt: t0
                )
            ]
        )
        #expect(try fetch(database) == ["GEN"])
    }

    @Test("book-level rows in different books yield the full set")
    func multipleBooksAllQualify() async throws {
        let (repository, database) = try makeFixture()
        try await repository.replace(
            target: .book, bookId: "GEN", chapterNumber: nil, verseStart: nil, verseEnd: nil,
            inserting: [
                BibleAnnotationRecord(
                    id: "g", target: .book, bookId: "GEN",
                    summary: "In the beginning.",
                    source: .user, modelId: "m", createdAt: t0
                )
            ]
        )
        try await repository.replace(
            target: .book, bookId: "JHN", chapterNumber: nil, verseStart: nil, verseEnd: nil,
            inserting: [
                BibleAnnotationRecord(
                    id: "j", target: .book, bookId: "JHN",
                    summary: "The Word.",
                    source: .user, modelId: "m", createdAt: t0
                )
            ]
        )
        #expect(try fetch(database) == ["GEN", "JHN"])
    }

    @Test("multiple book-level rows in one book yield a single set entry")
    func deduplicatedAcrossRows() async throws {
        let (repository, database) = try makeFixture()
        try await repository.replace(
            target: .book, bookId: "GEN", chapterNumber: nil, verseStart: nil, verseEnd: nil,
            inserting: [
                BibleAnnotationRecord(
                    id: "a", target: .book, bookId: "GEN",
                    summary: "First row.",
                    source: .user, modelId: "m", createdAt: t0
                ),
                BibleAnnotationRecord(
                    id: "b", target: .book, bookId: "GEN",
                    summary: "Second row.",
                    source: .user, modelId: "m", createdAt: t0
                ),
            ]
        )
        #expect(try fetch(database) == ["GEN"])
    }
}
