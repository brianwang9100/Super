import GRDBSnapshotTesting
import SnapshotTesting
import Testing
@testable import Bible

/// Snapshot of `BibleDatabase`'s migrated schema. The committed baseline is
/// a deterministic text dump of every `CREATE TABLE` / `CREATE INDEX`
/// statement across v1 / v2 / v3 — the database is empty, so no row
/// content appears. Any unintended schema drift (a dropped column, a
/// renamed type, an index that flipped uniqueness) fails this test with a
/// readable diff, catching shape regressions the column-set tests
/// elsewhere in `BibleDatabaseTests` would only notice once a query
/// started returning wrong data. Mirrors `Packages/Todo/Tests/TodoTests/
/// Database/TodoSchemaSnapshotTests.swift`.
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
