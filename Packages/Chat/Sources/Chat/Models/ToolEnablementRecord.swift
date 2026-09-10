import Foundation
import GRDB

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
