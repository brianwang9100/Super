/// Reads and writes the reader's single persisted chapter cursor.
///
/// Protocol-typed so the view model depends on the seam, not GRDB: tests
/// substitute an in-memory double, production uses
/// `GRDBBibleReadingPositionRepository`.
public protocol BibleReadingPositionRepository: Sendable {
    /// The persisted position, or `nil` on a fresh install.
    func load() async throws -> BibleReadingPositionRecord?

    /// Persist `record`, replacing any existing row.
    func save(_ record: BibleReadingPositionRecord) async throws
}
