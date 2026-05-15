import GRDB

/// GRDB-backed `BibleReadingPositionRepository` over the `bibleReadingPosition`
/// table.
///
/// The table holds at most one row (`BibleReadingPositionRecord.currentID`);
/// `save` upserts it so every write replaces the cursor in place.
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
