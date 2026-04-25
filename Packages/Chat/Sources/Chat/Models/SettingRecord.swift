import Foundation
import GRDB

/// Generic key/value store for Chat settings (`systemPrompt`, `accentHue`,
/// `defaultVerbosity`, `autoCompactEnabled`, etc.).
///
/// Values are stored as opaque strings so each setting controls its own
/// encoding (JSON for structured shapes, plain string for scalars). The
/// trade-off vs. a typed schema is intentional: it lets settings panes ship
/// without per-key migrations.
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
