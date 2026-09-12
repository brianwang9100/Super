import GRDB
import Testing
@testable import Bible

@Suite("Reading preferences persistence")
struct BibleReadingPreferencesRepositoryTests {
    @Test("Preferences replace their singleton and decode corrupt values safely")
    func roundTrip() async throws {
        let database = try BibleDatabase.makeInMemory()
        let repository = GRDBBibleReadingPreferencesRepository(database: database)
        #expect(try await repository.load() == nil)
        try await repository.save(.init(mode: .compare, secondaryTranslation: .bsb))
        #expect(try await repository.load()?.mode == .compare)
        try await repository.save(.init(mode: .study, secondaryTranslation: .web))
        #expect(try await repository.load()?.secondaryTranslation(primary: .web) == .kjv)
        try await database.queue.write { db in
            try db.execute(sql: "UPDATE bibleReadingPreferences SET modeId = 'unknown', secondaryTranslationId = 'unknown'")
        }
        let restored = try #require(try await repository.load())
        #expect(restored.mode == .book)
        #expect(restored.secondaryTranslation(primary: .kjv) == .web)
        #expect(restored.secondaryTranslation(primary: .web) == .kjv)
    }
}
