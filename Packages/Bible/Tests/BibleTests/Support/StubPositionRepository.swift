import Foundation
@testable import Bible

/// An in-memory `BibleReadingPositionRepository` returning a fixed record —
/// shared by the Bible tool tests that exercise current-translation resolution.
struct StubPositionRepository: BibleReadingPositionRepository {
    let record: BibleReadingPositionRecord?
    func load() async throws -> BibleReadingPositionRecord? { record }
    func save(_ record: BibleReadingPositionRecord) async throws {}
}
