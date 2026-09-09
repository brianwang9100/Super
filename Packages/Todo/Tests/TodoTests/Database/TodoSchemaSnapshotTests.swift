import GRDBSnapshotTesting
import SnapshotTesting
import Testing
@testable import Todo

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
