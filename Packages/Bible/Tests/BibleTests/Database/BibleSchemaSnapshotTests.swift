import GRDBSnapshotTesting
import SnapshotTesting
import Testing
@testable import Bible

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
