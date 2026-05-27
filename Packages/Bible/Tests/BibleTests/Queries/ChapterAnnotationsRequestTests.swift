import Foundation
import GRDB
import Testing
@testable import Bible

/// Tests for `ChapterAnnotationsRequest` — the per-chapter `@Query`
/// request that drives reactive bubble visibility in the chapter renderer.
@Suite("ChapterAnnotationsRequest")
struct ChapterAnnotationsRequestTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeFixture() throws -> (GRDBBibleAnnotationRepository, BibleDatabase) {
        let database = try BibleDatabase.makeInMemory()
        return (GRDBBibleAnnotationRepository(database: database), database)
    }

    private func fetch(_ database: BibleDatabase, book: String, chapter: Int) throws -> [BibleAnnotationRecord] {
        try database.queue.read { db in
            try ChapterAnnotationsRequest(bookId: book, chapterNumber: chapter).fetch(db)
        }
    }

    @Test("empty chapter yields an empty result")
    func emptyChapter() throws {
        let (_, database) = try makeFixture()
        let rows = try fetch(database, book: "ROM", chapter: 8)
        #expect(rows.isEmpty)
    }

    @Test("chapter-target and verse-target rows for the chapter both appear")
    func chapterAndVerseTargetsMix() async throws {
        let (repository, database) = try makeFixture()
        try await repository.replace(
            target: .chapter, bookId: "ROM", chapterNumber: 8,
            verseStart: nil, verseEnd: nil,
            inserting: [
                BibleAnnotationRecord(
                    id: "chap", target: .chapter, bookId: "ROM", chapterNumber: 8,
                    kind: .text, title: "Summary", body: "Life in the Spirit.",
                    source: .user, modelId: "m", createdAt: t0
                )
            ]
        )
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30,
            inserting: [
                BibleAnnotationRecord(
                    id: "v28-30", target: .verse, bookId: "ROM",
                    chapterNumber: 8, verseStart: 28, verseEnd: 30,
                    kind: .text, title: "Context", body: "Golden chain.",
                    source: .user, modelId: "m", createdAt: t0
                )
            ]
        )
        let rows = try fetch(database, book: "ROM", chapter: 8)
        // Both rows surface; book-target rows would not appear (chapterNumber is null).
        #expect(rows.map(\.id).sorted() == ["chap", "v28-30"])
    }

    @Test("rows from another chapter don't bleed through")
    func chapterIsolation() async throws {
        let (repository, database) = try makeFixture()
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 7, verseStart: 1, verseEnd: 1,
            inserting: [
                BibleAnnotationRecord(
                    id: "other", target: .verse, bookId: "ROM",
                    chapterNumber: 7, verseStart: 1, verseEnd: 1,
                    kind: .text, title: "Other", body: ".",
                    source: .user, modelId: "m", createdAt: t0
                )
            ]
        )
        let rows = try fetch(database, book: "ROM", chapter: 8)
        #expect(rows.isEmpty)
    }

    @Test("rows ordered by (createdAt ASC, id ASC)")
    func ordering() async throws {
        let (repository, database) = try makeFixture()
        let later = t0.addingTimeInterval(60)
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30,
            inserting: [
                BibleAnnotationRecord(
                    id: "b", target: .verse, bookId: "ROM",
                    chapterNumber: 8, verseStart: 28, verseEnd: 30,
                    kind: .text, title: "B", body: ".",
                    source: .user, modelId: "m", createdAt: t0
                ),
                BibleAnnotationRecord(
                    id: "a", target: .verse, bookId: "ROM",
                    chapterNumber: 8, verseStart: 28, verseEnd: 30,
                    kind: .text, title: "A", body: ".",
                    source: .user, modelId: "m", createdAt: t0
                ),
                BibleAnnotationRecord(
                    id: "c", target: .verse, bookId: "ROM",
                    chapterNumber: 8, verseStart: 28, verseEnd: 30,
                    kind: .text, title: "C", body: ".",
                    source: .user, modelId: "m", createdAt: later
                ),
            ]
        )
        let rows = try fetch(database, book: "ROM", chapter: 8)
        #expect(rows.map(\.id) == ["a", "b", "c"])
    }
}
