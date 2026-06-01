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
                    category: .summary, title: "Summary", body: "Life in the Spirit.",
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
                    category: .summary, title: "Context", body: "Golden chain.",
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
                    category: .summary, title: "Other", body: ".",
                    source: .user, modelId: "m", createdAt: t0
                )
            ]
        )
        let rows = try fetch(database, book: "ROM", chapter: 8)
        #expect(rows.isEmpty)
    }

    @Test("rows of equal category order by (createdAt ASC, id ASC)")
    func ordering() async throws {
        let (repository, database) = try makeFixture()
        let later = t0.addingTimeInterval(60)
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30,
            inserting: [
                BibleAnnotationRecord(
                    id: "b", target: .verse, bookId: "ROM",
                    chapterNumber: 8, verseStart: 28, verseEnd: 30,
                    category: .summary, title: "B", body: ".",
                    source: .user, modelId: "m", createdAt: t0
                ),
                BibleAnnotationRecord(
                    id: "a", target: .verse, bookId: "ROM",
                    chapterNumber: 8, verseStart: 28, verseEnd: 30,
                    category: .summary, title: "A", body: ".",
                    source: .user, modelId: "m", createdAt: t0
                ),
                BibleAnnotationRecord(
                    id: "c", target: .verse, bookId: "ROM",
                    chapterNumber: 8, verseStart: 28, verseEnd: 30,
                    category: .summary, title: "C", body: ".",
                    source: .user, modelId: "m", createdAt: later
                ),
            ]
        )
        let rows = try fetch(database, book: "ROM", chapter: 8)
        #expect(rows.map(\.id) == ["a", "b", "c"])
    }

    @Test("rows sort by canonical category order, not by creation time")
    func ordersByCategory() async throws {
        let (repository, database) = try makeFixture()
        // Insert with category reversed relative to createdAt; the category
        // key must win so the live chapter renderer's @Query feed follows
        // author → … → reference.
        func card(_ id: String, _ category: BibleAnnotationCategory, _ createdAt: Date) -> BibleAnnotationRecord {
            BibleAnnotationRecord(
                id: id, target: .verse, bookId: "ROM",
                chapterNumber: 8, verseStart: 28, verseEnd: 30,
                category: category, title: id, body: ".",
                source: .user, modelId: "m", createdAt: createdAt
            )
        }
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30,
            inserting: [
                card("ref", .reference, t0.addingTimeInterval(40)),
                card("clar", .clarification, t0.addingTimeInterval(30)),
                card("hist", .historical, t0.addingTimeInterval(20)),
                card("sum", .summary, t0.addingTimeInterval(10)),
                card("auth", .author, t0),
            ]
        )
        let rows = try fetch(database, book: "ROM", chapter: 8)
        #expect(rows.map(\.category) == [.author, .summary, .historical, .clarification, .reference])
        #expect(rows.map(\.id) == ["auth", "sum", "hist", "clar", "ref"])
    }
}
