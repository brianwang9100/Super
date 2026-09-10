import Foundation
import GRDB

/// Each setting owns its string encoding, avoiding per-key schema migrations.
public struct SettingRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "setting"

    public var key: String
    public var value: String

    public var id: String { key }

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
