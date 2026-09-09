import GRDB

public struct GRDBBibleReadingPositionRepository: BibleReadingPositionRepository {
    private let queue: DatabaseQueue

    public init(database: BibleDatabase) {
        self.queue = database.queue
    }

    public func load() async throws -> BibleReadingPositionRecord? {
        try await queue.read { db in
            try BibleReadingPositionRecord.fetchOne(db, key: BibleReadingPositionRecord.currentID)
        }
    }

    public func save(_ record: BibleReadingPositionRecord) async throws {
        try await queue.write { db in
            try record.save(db)
        }
    }
}
