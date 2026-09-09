import Core
import Foundation
import GRDB

public struct GRDBToolEnablementRepository: ToolEnablementRepository {
    private let queue: DatabaseQueue

    public init(database: ChatDatabase) {
        self.queue = database.queue
    }

    public func isEnabled(toolID: String) async throws -> Bool? {
        try await queue.read { db in
            try ToolEnablementRecord.fetchOne(db, key: toolID)?.isEnabled
        }
    }

    public func setEnabled(toolID: String, enabled: Bool) async throws {
        try await queue.write { db in
            try ToolEnablementRecord(toolId: toolID, isEnabled: enabled).save(db)
        }
    }

    public func allEnabled() async throws -> [String: Bool] {
        try await queue.read { db in
            let rows = try ToolEnablementRecord.fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.toolId, $0.isEnabled) })
        }
    }
}
