import Foundation
import GRDB

/// Persisted enablement state for a single tool, keyed by tool id.
///
/// Backs `GRDBToolEnablementRepository`'s conformance to Core's
/// `ToolEnablementRepository`, so user toggles in the Tools settings pane
/// survive an app restart and re-hydrate on `ToolRegistry.register(_:)`.
public struct ToolEnablementRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "toolEnablement"

    public var toolId: String
    public var isEnabled: Bool

    public var id: String { toolId }

    public init(toolId: String, isEnabled: Bool) {
        self.toolId = toolId
        self.isEnabled = isEnabled
    }
}
