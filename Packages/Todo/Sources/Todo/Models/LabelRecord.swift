import Foundation
import GRDB

/// A user-defined task label. `hue` is the 0–360° OKLCH (a perceptually
/// uniform color space) angle the chip resolves into background and
/// foreground colors at render time — the design generates these
/// client-side rather than persisting rendered colors. Names are unique
/// case-insensitively among non-deleted rows; the repository deduplicates
/// on `findActive` before insert.
public struct LabelRecord: Codable, TableRecord, FetchableRecord, PersistableRecord,
                           Sendable, Equatable, Identifiable {
    public static let databaseTableName = "label"

    public var id: String
    public var name: String
    public var hue: Double
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String,
        name: String,
        hue: Double,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.hue = hue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
