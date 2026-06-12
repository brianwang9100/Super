import Foundation
import GRDB
import Testing
@testable import Bible

/// Integration tests for `AnnotationCoverageRequest` — the raw distinct
/// books / chapters / summed-verses SQL backing the hub's coverage card.
/// Runs against an in-memory `bible.sqlite` so the hand-written SQL (the
/// `bookId || ':' || chapterNumber` distinct trick and the verse-range SUM)
/// is exercised, not just the view that renders the result.
@Suite("AnnotationCoverageRequest")
struct AnnotationCoverageRequestTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeFixture() throws -> (GRDBBibleAnnotationRepository, BibleDatabase) {
        let database = try BibleDatabase.makeInMemory()
        return (GRDBBibleAnnotationRepository(database: database), database)
    }

    private func coverage(_ database: BibleDatabase) throws -> AnnotationCoverage {
        try database.queue.read { try AnnotationCoverageRequest().fetch($0) }
    }

    private func record(
        _ id: String, target: BibleAnnotationTarget, bookId: String,
        chapterNumber: Int? = nil, verseStart: Int? = nil, verseEnd: Int? = nil
    ) -> BibleAnnotationRecord {
        BibleAnnotationRecord(
            id: id, target: target, bookId: bookId, chapterNumber: chapterNumber,
            verseStart: verseStart, verseEnd: verseEnd,
            summary: "s",
            source: .userBulk, modelId: "m", createdAt: t0
        )
    }

    @Test("an empty database reports zero coverage")
    func empty() throws {
        let (_, database) = try makeFixture()
        #expect(try coverage(database) == AnnotationCoverage.none)
    }

    @Test("counts distinct books and chapters, and sums verse ranges across books")
    func counts() async throws {
        let (repository, database) = try makeFixture()
        // Romans: a book prologue, a chapter summary (ch 8), and a 3-verse range.
        try await repository.replace(target: .book, bookId: "ROM", chapterNumber: nil,
            verseStart: nil, verseEnd: nil, inserting: [record("r-book", target: .book, bookId: "ROM")])
        try await repository.replace(target: .chapter, bookId: "ROM", chapterNumber: 8,
            verseStart: nil, verseEnd: nil,
            inserting: [record("r-ch8", target: .chapter, bookId: "ROM", chapterNumber: 8)])
        try await repository.replace(target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 28, verseEnd: 30,
            inserting: [record("r-v", target: .verse, bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30)])
        // Genesis: a chapter summary (ch 1) and a single-verse annotation.
        try await repository.replace(target: .chapter, bookId: "GEN", chapterNumber: 1,
            verseStart: nil, verseEnd: nil,
            inserting: [record("g-ch1", target: .chapter, bookId: "GEN", chapterNumber: 1)])
        try await repository.replace(target: .verse, bookId: "GEN", chapterNumber: 1,
            verseStart: 1, verseEnd: 1,
            inserting: [record("g-v", target: .verse, bookId: "GEN", chapterNumber: 1, verseStart: 1, verseEnd: 1)])

        let result = try coverage(database)
        #expect(result.books == 2)                     // ROM, GEN
        #expect(result.chapters == 2)                  // (ROM,8), (GEN,1) — book-target row (nil chapter) excluded
        #expect(result.verses == 4)                    // (30-28+1) + (1-1+1)
        // Canonical totals are carried through unchanged.
        #expect(result.totalBooks == 66)
        #expect(result.totalChapters == 1_189)
        #expect(result.totalVerses == 31_102)
    }

    @Test("the chapter count de-duplicates a chapter that carries both a summary and a verse note")
    func chapterDedup() async throws {
        let (repository, database) = try makeFixture()
        try await repository.replace(target: .chapter, bookId: "ROM", chapterNumber: 8,
            verseStart: nil, verseEnd: nil,
            inserting: [record("ch", target: .chapter, bookId: "ROM", chapterNumber: 8)])
        try await repository.replace(target: .verse, bookId: "ROM", chapterNumber: 8,
            verseStart: 1, verseEnd: 2,
            inserting: [record("v", target: .verse, bookId: "ROM", chapterNumber: 8, verseStart: 1, verseEnd: 2)])
        let result = try coverage(database)
        #expect(result.chapters == 1)                  // (ROM,8) counted once across both rows
        #expect(result.verses == 2)
    }
}
