import Core
import Foundation

/// Structured, non-text payload persisted alongside a `MessageRecord` —
/// serialized into its nullable `attachmentsJSON` column. A versioned shape:
/// future attachment kinds add fields here rather than new columns.
public struct MessageAttachments: Codable, Sendable, Equatable {
    /// Cross-applet record references attached to this message — Bible
    /// verse pills today. An empty array is never persisted (the column
    /// stays NULL), so a non-nil decode always carries at least one
    /// reference.
    public var references: [RecordReference]

    public init(references: [RecordReference]) {
        self.references = references
    }

    /// True when there is nothing worth persisting.
    public var isEmpty: Bool { references.isEmpty }
}
