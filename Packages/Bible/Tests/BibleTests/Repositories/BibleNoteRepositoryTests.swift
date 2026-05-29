import Foundation
import GRDB
import Testing
@testable import Bible

/// Integration tests for `GRDBBibleNoteRepository` against an in-memory
/// database — per-row insert, in-place update, newest-first listing across
/// the three target shapes, target-group isolation, and single-row deletion.
@Suite("GRDBBibleNoteRepository")
struct BibleNoteRepositoryTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeFixture() throws -> (GRDBBibleNoteRepository, BibleDatabase) {
        let database = try BibleDatabase.makeInMemory()
        return (GRDBBibleNoteRepository(database: database), database)
    }

    /// Build a verse-target note with sensible defaults.
    private func verseNote(
        id: String,
        bookId: String = "JHN",
        chapter: Int = 3,
        verseStart: Int = 16,
        verseEnd: Int = 18,
        body: String = "Body",
        source: BibleNoteSource = .user,
        modelId: String? = nil,
        createdAt: Date? = nil
    ) -> BibleNoteRecord {
        BibleNoteRecord(
            id: id,
            target: .verse,
            bookId: bookId,
            chapterNumber: chapter,
            verseStart: verseStart,
            verseEnd: verseEnd,
            body: body,
            source: source,
            modelId: modelId,
            createdAt: createdAt ?? t0,
            updatedAt: createdAt ?? t0
        )
    }

    // MARK: - Insert + list

    @Test("insert then list returns a verse target group's notes")
    func insertVerseGroup() async throws {
        let (repository, _) = try makeFixture()
        try await repository.insert(verseNote(id: "a", body: "First", createdAt: t0))
        try await repository.insert(verseNote(id: "b", body: "Second", createdAt: t0.addingTimeInterval(60)))
        let listed = try await repository.list(
            target: .verse, bookId: "JHN", chapterNumber: 3,
            verseStart: 16, verseEnd: 18
        )
        // Newest-first: "b" (later) precedes "a".
        #expect(listed.map(\.id) == ["b", "a"])
    }

    @Test("book-target note has nil chapter and verse columns")
    func insertBookNote() async throws {
        let (repository, _) = try makeFixture()
        let note = BibleNoteRecord(
            id: "bp", target: .book, bookId: "JHN",
            body: "The signs gospel.", source: .user,
            createdAt: t0, updatedAt: t0
        )
        try await repository.insert(note)
        let listed = try await repository.list(
            target: .book, bookId: "JHN",
            chapterNumber: nil, verseStart: nil, verseEnd: nil
        )
        #expect(listed.count == 1)
        #expect(listed.first?.chapterNumber == nil)
        #expect(listed.first?.verseStart == nil)
        #expect(listed.first?.verseEnd == nil)
    }

    @Test("chapter-target note has a chapter but no verses")
    func insertChapterNote() async throws {
        let (repository, _) = try makeFixture()
        let note = BibleNoteRecord(
            id: "cs", target: .chapter, bookId: "JHN", chapterNumber: 3,
            body: "Nicodemus by night.", source: .user,
            createdAt: t0, updatedAt: t0
        )
        try await repository.insert(note)
        let listed = try await repository.list(
            target: .chapter, bookId: "JHN", chapterNumber: 3,
            verseStart: nil, verseEnd: nil
        )
        #expect(listed.count == 1)
        #expect(listed.first?.chapterNumber == 3)
        #expect(listed.first?.verseStart == nil)
    }

    @Test("assistant note round-trips its source and modelId")
    func assistantProvenanceRoundTrips() async throws {
        let (repository, _) = try makeFixture()
        try await repository.insert(verseNote(id: "ai", source: .assistant, modelId: "claude"))
        let listed = try await repository.list(
            target: .verse, bookId: "JHN", chapterNumber: 3,
            verseStart: 16, verseEnd: 18
        )
        #expect(listed.first?.source == .assistant)
        #expect(listed.first?.modelId == "claude")
    }

    // MARK: - Ordering

    @Test("notes in a target group list by (createdAt DESC, id ASC)")
    func listOrdering() async throws {
        let (repository, _) = try makeFixture()
        let later = t0.addingTimeInterval(60)
        try await repository.insert(verseNote(id: "a", createdAt: t0))
        try await repository.insert(verseNote(id: "b", createdAt: t0))
        try await repository.insert(verseNote(id: "c", createdAt: later))
        let listed = try await repository.list(
            target: .verse, bookId: "JHN", chapterNumber: 3,
            verseStart: 16, verseEnd: 18
        )
        // "c" is newest; "a"/"b" share t0 and tie-break on id ascending.
        #expect(listed.map(\.id) == ["c", "a", "b"])
    }

    // MARK: - Update

    @Test("update changes only body and updatedAt")
    func updateBodyOnly() async throws {
        let (repository, _) = try makeFixture()
        try await repository.insert(verseNote(id: "a", body: "Original", createdAt: t0))
        let editedAt = t0.addingTimeInterval(3600)
        try await repository.update(id: "a", body: "Revised", updatedAt: editedAt)
        let listed = try await repository.list(
            target: .verse, bookId: "JHN", chapterNumber: 3,
            verseStart: 16, verseEnd: 18
        )
        #expect(listed.count == 1)
        #expect(listed.first?.body == "Revised")
        #expect(listed.first?.updatedAt == editedAt)
        // createdAt is immutable.
        #expect(listed.first?.createdAt == t0)
    }

    @Test("update on an unknown id is a no-op")
    func updateUnknownIsNoOp() async throws {
        let (repository, _) = try makeFixture()
        try await repository.insert(verseNote(id: "a", body: "Original"))
        try await repository.update(id: "missing", body: "X", updatedAt: t0)
        let listed = try await repository.list(
            target: .verse, bookId: "JHN", chapterNumber: 3,
            verseStart: 16, verseEnd: 18
        )
        #expect(listed.map(\.id) == ["a"])
        #expect(listed.first?.body == "Original")
    }

    // MARK: - Target-group isolation

    @Test("list scopes to the exact range and ignores sibling groups")
    func listIsolatesTargetGroup() async throws {
        let (repository, _) = try makeFixture()
        try await repository.insert(verseNote(id: "a", verseStart: 16, verseEnd: 18))
        try await repository.insert(verseNote(id: "b", verseStart: 19, verseEnd: 19))
        let firstGroup = try await repository.list(
            target: .verse, bookId: "JHN", chapterNumber: 3,
            verseStart: 16, verseEnd: 18
        )
        #expect(firstGroup.map(\.id) == ["a"])
    }

    // MARK: - Delete

    @Test("deleteOne removes the note by id")
    func deleteOneNote() async throws {
        let (repository, _) = try makeFixture()
        try await repository.insert(verseNote(id: "a", createdAt: t0))
        try await repository.insert(verseNote(id: "b", createdAt: t0.addingTimeInterval(60)))
        try await repository.deleteOne(id: "b")
        let listed = try await repository.list(
            target: .verse, bookId: "JHN", chapterNumber: 3,
            verseStart: 16, verseEnd: 18
        )
        #expect(listed.map(\.id) == ["a"])
    }

    @Test("deleteOne on an unknown id is a no-op")
    func deleteOneUnknown() async throws {
        let (repository, _) = try makeFixture()
        try await repository.insert(verseNote(id: "a"))
        try await repository.deleteOne(id: "does-not-exist")
        let listed = try await repository.list(
            target: .verse, bookId: "JHN", chapterNumber: 3,
            verseStart: 16, verseEnd: 18
        )
        #expect(listed.map(\.id) == ["a"])
    }
}
