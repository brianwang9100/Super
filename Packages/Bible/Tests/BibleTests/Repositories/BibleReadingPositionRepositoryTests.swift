import Foundation
import Testing
@testable import Bible

@Suite("GRDBBibleReadingPositionRepository")
struct BibleReadingPositionRepositoryTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRepository() throws -> GRDBBibleReadingPositionRepository {
        GRDBBibleReadingPositionRepository(database: try BibleDatabase.makeInMemory())
    }

    @Test("a fresh database has no reading position")
    func freshDatabaseLoadsNil() async throws {
        let repository = try makeRepository()
        #expect(try await repository.load() == nil)
    }

    @Test("a saved position round-trips")
    func saveThenLoad() async throws {
        let repository = try makeRepository()
        var history = BibleNavigationHistory(
            initialPosition: BiblePosition(bookId: "1PE", chapterNumber: 2)
        )
        let visited = history.visit(BiblePosition(bookId: "ROM", chapterNumber: 8))
        #expect(visited)
        let record = BibleReadingPositionRecord(
            bookId: "ROM", chapterNumber: 8, translationId: "WEB", updatedAt: now,
            navigationHistoryJSON: try BibleNavigationHistoryPayload.encode(history)
        )
        try await repository.save(record)
        #expect(try await repository.load() == record)
    }

    @Test("saving again replaces the single row in place")
    func saveReplaces() async throws {
        let repository = try makeRepository()
        let initialHistory = BibleNavigationHistory(
            initialPosition: BiblePosition(bookId: "ROM", chapterNumber: 8)
        )
        try await repository.save(BibleReadingPositionRecord(
            bookId: "ROM", chapterNumber: 8, translationId: "WEB", updatedAt: now,
            navigationHistoryJSON: try BibleNavigationHistoryPayload.encode(initialHistory)
        ))
        let updatedHistory = BibleNavigationHistory(
            initialPosition: BiblePosition(bookId: "PSA", chapterNumber: 23)
        )
        let updated = BibleReadingPositionRecord(
            bookId: "PSA", chapterNumber: 23, translationId: "KJV",
            updatedAt: now.addingTimeInterval(60),
            navigationHistoryJSON: try BibleNavigationHistoryPayload.encode(updatedHistory)
        )
        try await repository.save(updated)
        #expect(try await repository.load() == updated)
    }

    @Test("history cursor and both traversal directions survive database reopen")
    func historySurvivesDatabaseReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let a = BiblePosition(bookId: "1PE", chapterNumber: 2)
        let b = BiblePosition(bookId: "JHN", chapterNumber: 3)
        let c = BiblePosition(bookId: "PSA", chapterNumber: 23)
        var history = BibleNavigationHistory(initialPosition: a)
        let visitedB = history.visit(b)
        let visitedC = history.visit(c)
        let wentBack = history.goBack()
        #expect(visitedB)
        #expect(visitedC)
        #expect(wentBack)

        do {
            let database = try BibleDatabase.open(in: directory)
            let repository = GRDBBibleReadingPositionRepository(database: database)
            try await repository.save(BibleReadingPositionRecord(
                bookId: b.bookId,
                chapterNumber: b.chapterNumber,
                translationId: "WEB",
                updatedAt: now,
                navigationHistoryJSON: try BibleNavigationHistoryPayload.encode(history)
            ))
            try database.queue.close()
        }

        do {
            let database = try BibleDatabase.open(in: directory)
            let repository = GRDBBibleReadingPositionRepository(database: database)
            let record = try #require(try await repository.load())
            let restored = BibleNavigationHistoryPayload.restore(
                from: record.navigationHistoryJSON,
                position: BiblePosition(
                    bookId: record.bookId,
                    chapterNumber: record.chapterNumber
                ),
                catalog: .standard
            )

            #expect(restored.entries == [a, b, c])
            #expect(restored.current == b)
            #expect(restored.canGoBack)
            #expect(restored.canGoForward)
            try database.queue.close()
        }
    }
}
