import Foundation
import GRDB
import Testing
@testable import Bible

/// Integration tests for `GRDBBibleAnnotationRepository` against an
/// in-memory database — multi-row insertion, atomic replace, target-group
/// listing across the three target shapes, and single-row deletion.
@Suite("GRDBBibleAnnotationRepository")
struct BibleAnnotationRepositoryTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeFixture() throws -> (GRDBBibleAnnotationRepository, BibleDatabase) {
        let database = try BibleDatabase.makeInMemory()
        return (GRDBBibleAnnotationRepository(database: database), database)
    }

    /// Build a verse-target record with sensible defaults.
    private func verseRecord(
        id: String,
        bookId: String = "ROM",
        chapter: Int = 8,
        verseStart: Int = 28,
        verseEnd: Int = 30,
        title: String = "Card",
        body: String = "Body",
        category: BibleAnnotationCategory = .summary,
        createdAt: Date? = nil
    ) -> BibleAnnotationRecord {
        BibleAnnotationRecord(
            id: id,
            target: .verse,
            bookId: bookId,
            chapterNumber: chapter,
            verseStart: verseStart,
            verseEnd: verseEnd,
            category: category,
            title: title,
            body: body,
            source: .user,
            modelId: "test",
            createdAt: createdAt ?? t0
        )
    }

    // MARK: - Insert + list

    @Test("replace inserts a verse target group's rows")
    func insertVerseGroup() async throws {
        let (repository, _) = try makeFixture()
        let rows = [
            verseRecord(id: "a", title: "Author"),
            verseRecord(id: "b", title: "Context"),
        ]
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30, inserting: rows
        )
        let listed = try await repository.list(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30
        )
        #expect(listed.count == 2)
        #expect(listed.map(\.id) == ["a", "b"])
    }

    @Test("list returns rows in canonical category order, not creation order")
    func listOrdersByCategory() async throws {
        let (repository, _) = try makeFixture()
        // Insert with category reversed relative to createdAt, so a
        // creation-time sort would return them backwards. `list()` must
        // match the sheet's `@Query` order: author → … → reference.
        let rows = [
            verseRecord(id: "ref", category: .reference, createdAt: t0.addingTimeInterval(40)),
            verseRecord(id: "clar", category: .clarification, createdAt: t0.addingTimeInterval(30)),
            verseRecord(id: "hist", category: .historical, createdAt: t0.addingTimeInterval(20)),
            verseRecord(id: "sum", category: .summary, createdAt: t0.addingTimeInterval(10)),
            verseRecord(id: "auth", category: .author, createdAt: t0),
        ]
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30, inserting: rows
        )
        let listed = try await repository.list(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30
        )
        #expect(listed.map(\.category) == [.author, .summary, .historical, .clarification, .reference])
        #expect(listed.map(\.id) == ["auth", "sum", "hist", "clar", "ref"])
    }

    @Test("book-target rows have nil chapter and verse columns")
    func insertBookGroup() async throws {
        let (repository, _) = try makeFixture()
        let row = BibleAnnotationRecord(
            id: "bp", target: .book, bookId: "ROM",
            category: .author, title: "Prologue", body: "Long letter.",
            source: .user, modelId: "test", createdAt: t0
        )
        try await repository.replace(
            target: .book, bookId: "ROM",
            chapterNumber: nil, verseStart: nil, verseEnd: nil,
            inserting: [row]
        )
        let listed = try await repository.list(
            target: .book, bookId: "ROM",
            chapterNumber: nil, verseStart: nil, verseEnd: nil
        )
        #expect(listed.count == 1)
        #expect(listed.first?.chapterNumber == nil)
        #expect(listed.first?.verseStart == nil)
        #expect(listed.first?.verseEnd == nil)
    }

    @Test("chapter-target rows have a chapter but no verses")
    func insertChapterGroup() async throws {
        let (repository, _) = try makeFixture()
        let row = BibleAnnotationRecord(
            id: "cs", target: .chapter, bookId: "ROM", chapterNumber: 8,
            category: .summary, title: "Summary", body: "Life in the Spirit.",
            source: .user, modelId: "test", createdAt: t0
        )
        try await repository.replace(
            target: .chapter, bookId: "ROM", chapterNumber: 8,
            verseStart: nil, verseEnd: nil, inserting: [row]
        )
        let listed = try await repository.list(
            target: .chapter, bookId: "ROM", chapterNumber: 8,
            verseStart: nil, verseEnd: nil
        )
        #expect(listed.count == 1)
        #expect(listed.first?.chapterNumber == 8)
        #expect(listed.first?.verseStart == nil)
    }

    // MARK: - Ordering

    @Test("rows in a target group are listed by (createdAt ASC, id ASC)")
    func listOrdering() async throws {
        let (repository, _) = try makeFixture()
        let later = t0.addingTimeInterval(60)
        let rows = [
            verseRecord(id: "c", createdAt: later),
            verseRecord(id: "a", createdAt: t0),
            verseRecord(id: "b", createdAt: t0),
        ]
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30, inserting: rows
        )
        let listed = try await repository.list(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30
        )
        // Two rows share `t0` and tie-break on id; the later row sorts last.
        #expect(listed.map(\.id) == ["a", "b", "c"])
    }

    // MARK: - Replace semantics

    @Test("replace swaps the target group's rows wholesale")
    func replaceSwapsGroup() async throws {
        let (repository, _) = try makeFixture()
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30,
            inserting: [verseRecord(id: "old-1"), verseRecord(id: "old-2")]
        )
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30,
            inserting: [verseRecord(id: "new-1")]
        )
        let listed = try await repository.list(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30
        )
        #expect(listed.map(\.id) == ["new-1"])
    }

    @Test("replace with empty inserting array clears the target group")
    func replaceEmptyClears() async throws {
        let (repository, _) = try makeFixture()
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30,
            inserting: [verseRecord(id: "x")]
        )
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30,
            inserting: []
        )
        let listed = try await repository.list(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30
        )
        #expect(listed.isEmpty)
    }

    @Test("replace doesn't touch a sibling target group")
    func replaceLeavesOtherGroupsAlone() async throws {
        let (repository, _) = try makeFixture()
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30,
            inserting: [verseRecord(id: "a", verseStart: 28, verseEnd: 30)]
        )
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 32, verseEnd: 32,
            inserting: [verseRecord(id: "b", verseStart: 32, verseEnd: 32)]
        )
        // Replacing v32 must not blow away v28-30.
        let firstGroup = try await repository.list(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30
        )
        #expect(firstGroup.map(\.id) == ["a"])
    }

    @Test("replace rejects records whose position doesn't match the target group")
    func replaceRejectsMismatchedRecord() async throws {
        let (repository, _) = try makeFixture()
        let mismatched = verseRecord(id: "wrong", verseStart: 99, verseEnd: 100)
        await #expect(throws: BibleAnnotationRepositoryError.recordOutsideTargetGroup(id: "wrong")) {
            try await repository.replace(
                target: .verse, bookId: "ROM", chapterNumber: 8,
                verseStart: 28, verseEnd: 30, inserting: [mismatched]
            )
        }
    }

    @Test("replace is atomic — a mid-call validation throw leaves seed rows intact")
    func replaceIsAtomicOnValidationFailure() async throws {
        let (repository, _) = try makeFixture()
        // Seed the target group with an existing row.
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30,
            inserting: [verseRecord(id: "original")]
        )
        // Now replace with a batch where the second record doesn't match
        // the target group. `replace` walks the batch up-front and throws
        // before touching the table — the seed row must survive.
        let mismatched = verseRecord(id: "bad", verseStart: 99, verseEnd: 100)
        await #expect(throws: BibleAnnotationRepositoryError.recordOutsideTargetGroup(id: "bad")) {
            try await repository.replace(
                target: .verse, bookId: "ROM", chapterNumber: 8,
                verseStart: 28, verseEnd: 30,
                inserting: [verseRecord(id: "new-1"), mismatched]
            )
        }
        let listed = try await repository.list(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30
        )
        // Original survives; neither the validated `new-1` row nor the
        // mismatched `bad` row landed.
        #expect(listed.map(\.id) == ["original"])
    }

    // MARK: - Single-row delete

    @Test("deleteOne removes the row by id")
    func deleteOneRow() async throws {
        let (repository, _) = try makeFixture()
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30,
            inserting: [verseRecord(id: "a"), verseRecord(id: "b")]
        )
        try await repository.deleteOne(id: "a")
        let listed = try await repository.list(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30
        )
        #expect(listed.map(\.id) == ["b"])
    }

    @Test("deleteOne on an unknown id is a no-op")
    func deleteOneUnknown() async throws {
        let (repository, _) = try makeFixture()
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30,
            inserting: [verseRecord(id: "a")]
        )
        try await repository.deleteOne(id: "does-not-exist")
        let listed = try await repository.list(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30
        )
        #expect(listed.map(\.id) == ["a"])
    }
}
