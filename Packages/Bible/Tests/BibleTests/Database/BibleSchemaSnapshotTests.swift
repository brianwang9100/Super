import GRDBSnapshotTesting
import SnapshotTesting
import Testing
@testable import Bible

/// Complete SQL snapshot after all Bible migrations, including table/column shape,
/// defaults, foreign keys, and index uniqueness. Historical data upgrades and
/// SQLite constraint behavior remain covered independently in `BibleDatabaseTests`.
@Suite("BibleDatabase schema snapshot")
struct BibleSchemaSnapshotTests {
    @Test func schemaMatchesBaseline() throws {
        let database = try BibleDatabase.makeInMemory()
        let failure = verifySnapshot(of: database.queue, as: .dumpContent())
        if let failure {
            Issue.record("\(failure)")
        }
    }
}
