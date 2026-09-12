public protocol BibleReadingPreferencesRepository: Sendable {
    func load() async throws -> BibleReadingPreferencesRecord?
    func save(_ record: BibleReadingPreferencesRecord) async throws
}
