public protocol BibleReadingPositionRepository: Sendable {
    /// Nil before a position has been saved.
    func load() async throws -> BibleReadingPositionRecord?

    /// Replaces the existing cursor.
    func save(_ record: BibleReadingPositionRecord) async throws
}
