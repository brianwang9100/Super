import Foundation
import Testing
@testable import Bible

/// Integration tests for `GRDBBibleReadingPositionRepository` against an
/// in-memory database — the fresh-install, round-trip, and replace-in-place
/// behaviours the single-row reading cursor relies on.
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
        let record = BibleReadingPositionRecord(
            bookId: "ROM", chapterNumber: 8, translationId: "WEB", updatedAt: now
        )
        try await repository.save(record)
        #expect(try await repository.load() == record)
    }

    @Test("saving again replaces the single row in place")
    func saveReplaces() async throws {
        let repository = try makeRepository()
        try await repository.save(BibleReadingPositionRecord(
            bookId: "ROM", chapterNumber: 8, translationId: "WEB", updatedAt: now
        ))
        let updated = BibleReadingPositionRecord(
            bookId: "PSA", chapterNumber: 23, translationId: "WEB",
            updatedAt: now.addingTimeInterval(60)
        )
        try await repository.save(updated)
        #expect(try await repository.load() == updated)
    }
}
