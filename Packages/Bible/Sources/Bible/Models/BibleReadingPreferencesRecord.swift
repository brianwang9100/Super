import GRDB

public struct BibleReadingPreferencesRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "bibleReadingPreferences"
    public static let currentID = "current"
    public var id: String
    public var modeId: String
    public var secondaryTranslationId: String

    public var mode: BibleReadingMode { BibleReadingMode(rawValue: modeId) ?? .book }
    public func secondaryTranslation(primary: BibleTranslation) -> BibleTranslation {
        let candidate = BibleTranslation(rawValue: secondaryTranslationId) ?? .web
        return candidate == primary ? (primary == .web ? .kjv : .web) : candidate
    }

    public init(mode: BibleReadingMode = .book, secondaryTranslation: BibleTranslation = .web) {
        id = Self.currentID
        modeId = mode.rawValue
        secondaryTranslationId = secondaryTranslation.rawValue
    }
}
