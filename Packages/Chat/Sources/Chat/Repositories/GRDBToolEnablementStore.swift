import Core
import Foundation
import GRDB

/// GRDB-backed conformer for Core's `ToolEnablementStore`. The Chat package
/// owns it because Chat owns the database; Core stays GRDB-free.
///
/// The protocol's parameter label is `toolID:` (Core convention); the
/// underlying record column is `toolId` (Chat package convention). The
/// label/field mismatch is intentional and isolated to this file.
public struct GRDBToolEnablementStore: ToolEnablementStore {
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
