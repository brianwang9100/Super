import GRDB

public struct GRDBBibleReadingPreferencesRepository: BibleReadingPreferencesRepository {
    private let queue: DatabaseQueue

    public init(database: BibleDatabase) { queue = database.queue }

    public func load() async throws -> BibleReadingPreferencesRecord? {
        try await queue.read { db in
            try BibleReadingPreferencesRecord.fetchOne(db, key: BibleReadingPreferencesRecord.currentID)
        }
    }

    public func save(_ record: BibleReadingPreferencesRecord) async throws {
        try await queue.write { db in try record.save(db) }
    }
}
