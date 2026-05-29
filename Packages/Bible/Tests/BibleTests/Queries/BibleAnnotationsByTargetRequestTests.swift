import Foundation
import GRDB
import Testing
@testable import Bible

/// Tests for `BibleAnnotationsByTargetRequest` — the single-target
/// reactive feed that drives the annotation sheet's `@Query`. The query
/// must return only rows matching the spec; any cross-target leakage
/// breaks the sheet's card list.
@Suite("BibleAnnotationsByTargetRequest")
struct BibleAnnotationsByTargetRequestTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeFixture() throws -> (GRDBBibleAnnotationRepository, BibleDatabase) {
        let database = try BibleDatabase.makeInMemory()
        return (GRDBBibleAnnotationRepository(database: database), database)
    }

    private func fetch(_ database: BibleDatabase, spec: BibleAnnotationTargetSpec) throws -> [BibleAnnotationRecord] {
        try database.queue.read { db in
            try BibleAnnotationsByTargetRequest(spec: spec).fetch(db)
        }
    }

    @Test("empty database yields an empty result")
    func empty() throws {
        let (_, database) = try makeFixture()
        let rows = try fetch(database, spec: .book(bookId: "ROM"))
        #expect(rows.isEmpty)
    }

    @Test("book spec returns only the book-target row, not chapter or verse rows for the same book")
    func bookIsolatesFromChapterAndVerse() async throws {
        let (repository, database) = try makeFixture()
        let book = BibleAnnotationRecord(
            id: "book", target: .book, bookId: "ROM", chapterNumber: nil,
            kind: .text, title: "Author", body: "Paul.",
            source: .user, modelId: "m", createdAt: t0
        )
        let chapter = BibleAnnotationRecord(
            id: "chap", target: .chapter, bookId: "ROM", chapterNumber: 8,
            kind: .text, title: "Summary", body: "Spirit life.",
            source: .user, modelId: "m", createdAt: t0
        )
        let verse = BibleAnnotationRecord(
            id: "verse", target: .verse, bookId: "ROM",
            chapterNumber: 8, verseStart: 28, verseEnd: 30,
            kind: .text, title: "Context", body: "Suffering.",
            source: .user, modelId: "m", createdAt: t0
        )
        try await repository.replace(
            target: .book, bookId: "ROM", chapterNumber: nil,
            verseStart: nil, verseEnd: nil,
            inserting: [book]
        )
        try await repository.replace(
            target: .chapter, bookId: "ROM", chapterNumber: 8,
            verseStart: nil, verseEnd: nil,
            inserting: [chapter]
        )
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30,
            inserting: [verse]
        )

        let rows = try fetch(database, spec: .book(bookId: "ROM"))
        #expect(rows.count == 1)
        #expect(rows.first?.id == "book")
    }

    @Test("chapter spec returns only the chapter-target rows for that chapter")
    func chapterIsolatesFromVerse() async throws {
        let (repository, database) = try makeFixture()
        try await repository.replace(
            target: .chapter, bookId: "ROM", chapterNumber: 8,
            verseStart: nil, verseEnd: nil,
            inserting: [
                BibleAnnotationRecord(
                    id: "chap8", target: .chapter, bookId: "ROM", chapterNumber: 8,
                    kind: .text, title: "Summary", body: "Spirit life.",
                    source: .user, modelId: "m", createdAt: t0
                )
            ]
        )
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30,
            inserting: [
                BibleAnnotationRecord(
                    id: "verse", target: .verse, bookId: "ROM",
                    chapterNumber: 8, verseStart: 28, verseEnd: 30,
                    kind: .text, title: "Context", body: "Suffering.",
                    source: .user, modelId: "m", createdAt: t0
                )
            ]
        )

        let rows = try fetch(database, spec: .chapter(bookId: "ROM", chapterNumber: 8))
        #expect(rows.count == 1)
        #expect(rows.first?.id == "chap8")
    }

    @Test("verseRange spec returns only the exact range; sibling ranges are excluded")
    func verseRangeIsolatesFromSiblingRanges() async throws {
        let (repository, database) = try makeFixture()
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30,
            inserting: [
                BibleAnnotationRecord(
                    id: "a", target: .verse, bookId: "ROM",
                    chapterNumber: 8, verseStart: 28, verseEnd: 30,
                    kind: .text, title: "X", body: "Y.",
                    source: .user, modelId: "m", createdAt: t0
                )
            ]
        )
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 31, verseEnd: 32,
            inserting: [
                BibleAnnotationRecord(
                    id: "b", target: .verse, bookId: "ROM",
                    chapterNumber: 8, verseStart: 31, verseEnd: 32,
                    kind: .text, title: "X", body: "Y.",
                    source: .user, modelId: "m", createdAt: t0
                )
            ]
        )

        let rows = try fetch(
            database,
            spec: .verseRange(bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30)
        )
        #expect(rows.count == 1)
        #expect(rows.first?.id == "a")
    }

    @Test("rows in the target group return in createdAt-then-id order")
    func ordering() async throws {
        let (repository, database) = try makeFixture()
        // Insert out-of-order createdAt + same-second IDs to lock both
        // sort keys in: the older row sorts first; same-time IDs sort by
        // id ascending ("a" before "b").
        try await repository.replace(
            target: .chapter, bookId: "ROM", chapterNumber: 8,
            verseStart: nil, verseEnd: nil,
            inserting: [
                BibleAnnotationRecord(
                    id: "b", target: .chapter, bookId: "ROM", chapterNumber: 8,
                    kind: .text, title: "Second", body: "x.",
                    source: .user, modelId: "m", createdAt: t0.addingTimeInterval(1)
                ),
                BibleAnnotationRecord(
                    id: "a", target: .chapter, bookId: "ROM", chapterNumber: 8,
                    kind: .text, title: "First", body: "x.",
                    source: .user, modelId: "m", createdAt: t0
                ),
                BibleAnnotationRecord(
                    id: "c", target: .chapter, bookId: "ROM", chapterNumber: 8,
                    kind: .text, title: "First-tie", body: "x.",
                    source: .user, modelId: "m", createdAt: t0
                ),
            ]
        )

        let rows = try fetch(database, spec: .chapter(bookId: "ROM", chapterNumber: 8))
        #expect(rows.map(\.id) == ["a", "c", "b"])
    }
}
