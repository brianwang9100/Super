import GRDBSnapshotTesting
import SnapshotTesting
import Testing
@testable import Todo

/// Snapshot of `TodoDatabase`'s migrated schema. The committed baseline is
/// a deterministic text dump of the v1 `CREATE TABLE` / `CREATE INDEX`
/// statements (the database is empty, so no row content appears) — any
/// unintended schema drift fails this test with a readable diff. The dump
/// is plain SQL text, so the baseline is stable across machines.
@Suite("TodoDatabase schema snapshot")
struct TodoSchemaSnapshotTests {
    @Test func v1SchemaMatchesBaseline() throws {
        let db = try TodoDatabase.makeInMemory()
        let failure = verifySnapshot(of: db.queue, as: .dumpContent())
        if let failure {
            Issue.record("\(failure)")
        }
    }
}
