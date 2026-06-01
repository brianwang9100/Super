import Foundation
import GRDB
import Testing
@testable import Bible

/// Tests for the three note `@Query` requests — `ChapterNotesRequest`,
/// `NotesForRangeRequest`, and `BookNotesExistenceRequest` — plus a
/// cross-write check proving a repository write is observable through the
/// request's `fetch`, the mechanism `@Query` re-renders on.
@Suite("Note queries")
struct NoteQueriesTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeFixture() throws -> (GRDBBibleNoteRepository, BibleDatabase) {
        let database = try BibleDatabase.makeInMemory()
        return (GRDBBibleNoteRepository(database: database), database)
    }

    private func verseNote(
        id: String,
        bookId: String = "JHN",
        chapter: Int = 3,
        verseStart: Int = 16,
        verseEnd: Int = 18,
        createdAt: Date? = nil
    ) -> BibleNoteRecord {
        BibleNoteRecord(
            id: id, target: .verse, bookId: bookId, chapterNumber: chapter,
            verseStart: verseStart, verseEnd: verseEnd, body: ".", source: .user,
            createdAt: createdAt ?? t0, updatedAt: createdAt ?? t0
        )
    }

    // MARK: - ChapterNotesRequest

    @Test("ChapterNotesRequest surfaces chapter- and verse-target rows, newest first")
    func chapterMixesTargetsNewestFirst() async throws {
        let (repository, database) = try makeFixture()
        try await repository.insert(BibleNoteRecord(
            id: "chap", target: .chapter, bookId: "JHN", chapterNumber: 3,
            body: "Nicodemus.", source: .user, createdAt: t0, updatedAt: t0
        ))
        try await repository.insert(verseNote(id: "v16-18", createdAt: t0.addingTimeInterval(60)))
        // A book-target note must NOT appear (its chapterNumber is nil).
        try await repository.insert(BibleNoteRecord(
            id: "book", target: .book, bookId: "JHN",
            body: "Whole book.", source: .user, createdAt: t0, updatedAt: t0
        ))
        let rows = try await database.queue.read { db in
            try ChapterNotesRequest(bookId: "JHN", chapterNumber: 3).fetch(db)
        }
        #expect(rows.map(\.id) == ["v16-18", "chap"])
    }

    @Test("ChapterNotesRequest isolates the chapter")
    func chapterIsolation() async throws {
        let (repository, database) = try makeFixture()
        try await repository.insert(verseNote(id: "ch4", chapter: 4))
        let rows = try await database.queue.read { db in
            try ChapterNotesRequest(bookId: "JHN", chapterNumber: 3).fetch(db)
        }
        #expect(rows.isEmpty)
    }

    // MARK: - NotesForRangeRequest

    @Test("NotesForRangeRequest matches one exact verse range and ignores siblings")
    func rangeRequestExactMatch() async throws {
        let (repository, database) = try makeFixture()
        try await repository.insert(verseNote(id: "a", verseStart: 16, verseEnd: 18))
        try await repository.insert(verseNote(id: "b", verseStart: 19, verseEnd: 19))
        let rows = try await database.queue.read { db in
            try NotesForRangeRequest(
                target: .verse, bookId: "JHN", chapterNumber: 3,
                verseStart: 16, verseEnd: 18
            ).fetch(db)
        }
        #expect(rows.map(\.id) == ["a"])
    }

    @Test("NotesForRangeRequest matches a chapter target (nil verse columns)")
    func rangeRequestChapterTarget() async throws {
        let (repository, database) = try makeFixture()
        try await repository.insert(BibleNoteRecord(
            id: "chap", target: .chapter, bookId: "JHN", chapterNumber: 3,
            body: ".", source: .user, createdAt: t0, updatedAt: t0
        ))
        // A verse-target note in the same chapter must not leak into the
        // chapter-target group.
        try await repository.insert(verseNote(id: "verse"))
        let rows = try await database.queue.read { db in
            try NotesForRangeRequest(
                target: .chapter, bookId: "JHN", chapterNumber: 3
            ).fetch(db)
        }
        #expect(rows.map(\.id) == ["chap"])
    }

    @Test("a repository write is visible through NotesForRangeRequest.fetch")
    func writeIsObservable() async throws {
        let (repository, database) = try makeFixture()
        func currentCount() throws -> Int {
            try database.queue.read { db in
                try NotesForRangeRequest(
                    target: .verse, bookId: "JHN", chapterNumber: 3,
                    verseStart: 16, verseEnd: 18
                ).fetch(db).count
            }
        }
        #expect(try currentCount() == 0)
        try await repository.insert(verseNote(id: "a"))
        // The fetch the @Query observes now reflects the outside write — the
        // reactivity contract the list sheet relies on.
        #expect(try currentCount() == 1)
    }

    // MARK: - BookNotesExistenceRequest

    @Test("BookNotesExistenceRequest returns only books with a book-level note")
    func existenceBookLevelOnly() async throws {
        let (repository, database) = try makeFixture()
        // JHN has only a verse-level note → excluded (its verse glyph carries
        // it; the book glyph stays outline so its tap composes a book note).
        try await repository.insert(verseNote(id: "v", bookId: "JHN"))
        // A chapter-level note also doesn't count toward the book glyph.
        try await repository.insert(BibleNoteRecord(
            id: "luk-ch", target: .chapter, bookId: "LUK", chapterNumber: 4,
            body: ".", source: .user, createdAt: t0, updatedAt: t0
        ))
        // ROM has a genuine book-level note → included.
        try await repository.insert(BibleNoteRecord(
            id: "rom", target: .book, bookId: "ROM",
            body: ".", source: .user, createdAt: t0, updatedAt: t0
        ))
        let ids = try await database.queue.read { db in
            try BookNotesExistenceRequest().fetch(db)
        }
        #expect(ids == ["ROM"])
    }

    @Test("BookNotesExistenceRequest is empty on a fresh database")
    func existenceEmpty() throws {
        let (_, database) = try makeFixture()
        let ids = try database.queue.read { db in
            try BookNotesExistenceRequest().fetch(db)
        }
        #expect(ids.isEmpty)
    }
}
