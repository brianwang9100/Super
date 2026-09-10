import Foundation
@testable import Bible

struct StubPositionRepository: BibleReadingPositionRepository {
    let record: BibleReadingPositionRecord?
    func load() async throws -> BibleReadingPositionRecord? { record }
    func save(_ record: BibleReadingPositionRecord) async throws {}
}
