import Foundation
import GRDB
import Testing
@testable import Bible

/// Tests for `AnnotatedChaptersRequest` — the Generate sheet's per-chapter "Done"
/// badge source: the set of `(bookId, chapterNumber)` pairs carrying any
/// chapter- or verse-level annotation (book-level rows, whose `chapterNumber` is
/// nil, are excluded).
@Suite("AnnotatedChaptersRequest")
struct AnnotatedChaptersRequestTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeFixture() throws -> (GRDBBibleAnnotationRepository, BibleDatabase) {
        let database = try BibleDatabase.makeInMemory()
        return (GRDBBibleAnnotationRepository(database: database), database)
    }

    private func fetch(_ database: BibleDatabase) throws -> Set<ChapterRef> {
        try database.queue.read { db in
            try AnnotatedChaptersRequest().fetch(db)
        }
    }

    @Test("empty database yields the empty set")
    func emptyDatabase() throws {
        let (_, database) = try makeFixture()
        #expect(try fetch(database).isEmpty)
    }

    @Test("chapter- and verse-level rows contribute their chapter; book-level rows do not")
    func chapterAndVerseCountButBookDoesNot() async throws {
        let (repository, database) = try makeFixture()
        try await repository.replace(
            target: .chapter, bookId: "JHN", chapterNumber: 3, verseStart: nil, verseEnd: nil,
            inserting: [
                BibleAnnotationRecord(
                    id: "c", target: .chapter, bookId: "JHN", chapterNumber: 3,
                    summary: "S.", source: .user, modelId: "m", createdAt: t0
                )
            ]
        )
        try await repository.replace(
            target: .verse, bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30,
            inserting: [
                BibleAnnotationRecord(
                    id: "v", target: .verse, bookId: "ROM", chapterNumber: 8,
                    verseStart: 28, verseEnd: 30,
                    summary: "T.", source: .user, modelId: "m", createdAt: t0
                )
            ]
        )
        try await repository.replace(
            target: .book, bookId: "GEN", chapterNumber: nil, verseStart: nil, verseEnd: nil,
            inserting: [
                BibleAnnotationRecord(
                    id: "b", target: .book, bookId: "GEN",
                    summary: "P.", source: .user, modelId: "m", createdAt: t0
                )
            ]
        )
        #expect(try fetch(database) == [
            ChapterRef(bookID: "JHN", number: 3),
            ChapterRef(bookID: "ROM", number: 8),
        ])
    }

    @Test("multiple rows in one chapter collapse to a single pair")
    func deduplicatedWithinAChapter() async throws {
        let (repository, database) = try makeFixture()
        try await repository.replace(
            target: .chapter, bookId: "ROM", chapterNumber: 1, verseStart: nil, verseEnd: nil,
            inserting: [
                BibleAnnotationRecord(
                    id: "a", target: .chapter, bookId: "ROM", chapterNumber: 1,
                    summary: "A.", source: .user, modelId: "m", createdAt: t0
                ),
                BibleAnnotationRecord(
                    id: "b", target: .chapter, bookId: "ROM", chapterNumber: 1,
                    summary: "B.", source: .user, modelId: "m", createdAt: t0
                ),
            ]
        )
        #expect(try fetch(database) == [ChapterRef(bookID: "ROM", number: 1)])
    }
}
