import Foundation
import GRDB
import GRDBSnapshotTesting
import SnapshotTesting
import Testing
@testable import Chat

/// Tests for `registerChatMigrations` v1 schema — table set, column shape,
/// FK (foreign key) cascade, and index inventory.
@Suite("ChatDatabase migrations")
struct ChatDatabaseMigrationTests {

    @Test func v1CreatesEverySchemaTable() async throws {
        let db = try ChatDatabase.makeInMemory()
        let names = try await db.queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                ORDER BY name
            """)
        }
        #expect(names == [
            "compactionCheckpoint",
            "conversation",
            "message",
            "modelConfiguration",
            "setting",
            "toolCall",
            "toolEnablement",
        ])
    }

    @Test func v1CreatesEveryExpectedIndex() async throws {
        let db = try ChatDatabase.makeInMemory()
        let names = try await db.queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='index' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                ORDER BY name
            """)
        }
        #expect(names == [
            "compactionCheckpoint_on_conversationId_isLive",
            "conversation_on_updatedAt",
            "message_on_conversationId_createdAt",
            "modelConfiguration_unique_selected",
            "toolCall_on_conversationId",
            "toolCall_on_messageId",
            "toolCall_on_status",
        ])
    }

    @Test func partialUniqueIndexBlocksTwoSelectedRows() async throws {
        let db = try ChatDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let url = URL(string: "https://example.com/v1")!

        try await db.queue.write { db in
            try ModelConfigurationRecord(
                id: "a", name: "A", baseURL: url, apiKeyRef: "ka",
                modelId: "m", isSelected: true, createdAt: now
            ).insert(db)
        }

        await #expect(throws: (any Error).self) {
            try await db.queue.write { db in
                try ModelConfigurationRecord(
                    id: "b", name: "B", baseURL: url, apiKeyRef: "kb",
                    modelId: "m", isSelected: true, createdAt: now
                ).insert(db)
            }
        }

        // The second insert with isSelected = false must succeed — the
        // partial index only constrains isSelected = 1 rows.
        try await db.queue.write { db in
            try ModelConfigurationRecord(
                id: "c", name: "C", baseURL: url, apiKeyRef: "kc",
                modelId: "m", isSelected: false, createdAt: now
            ).insert(db)
        }
    }

    @Test func messageColumnsMatchRecordShape() async throws {
        let db = try ChatDatabase.makeInMemory()
        let columns = try await db.queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(message)")
                .map { ($0["name"] as String, $0["type"] as String, $0["notnull"] as Int) }
        }
        let lookup = Dictionary(uniqueKeysWithValues: columns.map { ($0.0, ($0.1, $0.2)) })

        #expect(lookup["id"]?.0 == "TEXT")
        #expect(lookup["conversationId"]?.0 == "TEXT")
        #expect(lookup["conversationId"]?.1 == 1)
        #expect(lookup["role"]?.0 == "TEXT")
        #expect(lookup["role"]?.1 == 1)
        #expect(lookup["content"]?.0 == "TEXT")
        #expect(lookup["toolCallId"]?.0 == "TEXT")
        #expect(lookup["toolCallId"]?.1 == 0)
        #expect(lookup["createdAt"]?.0 == "DATETIME")
        #expect(lookup["tokenCount"]?.0 == "INTEGER")
        #expect(lookup["tokenCount"]?.1 == 0)
    }

    @Test func deletingConversationCascadesToMessagesAndToolCalls() async throws {
        let db = try ChatDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try await db.queue.write { db in
            try ConversationRecord(id: "c1", title: "Cascade", createdAt: now, updatedAt: now)
                .insert(db)
            try MessageRecord(
                id: "m1", conversationId: "c1", role: .user, content: "hi", createdAt: now
            ).insert(db)
            try ToolCallRecord(
                id: "tc1",
                messageId: "m1",
                conversationId: "c1",
                toolName: "todo.create",
                parameters: "{}",
                status: .pending,
                createdAt: now
            ).insert(db)
        }

        _ = try await db.queue.write { db in
            try ConversationRecord.deleteOne(db, key: "c1")
        }

        let counts = try await db.queue.read { db in
            (
                messages: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? -1,
                toolCalls: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM toolCall") ?? -1
            )
        }
        #expect(counts.messages == 0)
        #expect(counts.toolCalls == 0)
    }

    @Test func migratorIsIdempotent() async throws {
        let queue = try DatabaseQueue()
        try ChatDatabase.migrator().migrate(queue)
        try ChatDatabase.migrator().migrate(queue)

        let count = try await queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
            """) ?? -1
        }
        #expect(count == 7)
    }

    /// End-to-end schema + content snapshot via `GRDBSnapshotTesting`.
    /// Catches column-type drift, FK clauses, and DEFAULT expressions
    /// that the targeted PRAGMA assertions don't cover. Snapshot files
    /// land under `Tests/ChatTests/Database/__Snapshots__/`.
    @Test func v1SchemaSnapshot() async throws {
        let db = try ChatDatabase.makeInMemory()
        assertSnapshot(of: db.queue, as: .dumpContent())
    }
}
