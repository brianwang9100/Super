import Foundation
import GRDB
import GRDBSnapshotTesting
import SnapshotTesting
import Testing
@testable import Chat

@Suite("ChatDatabase migrations")
struct ChatDatabaseMigrationTests {

    @Test func openAppliesFileProtectionToOnDiskDatabase() throws {
        // Data Protection is meaningful only on iOS hardware. macOS may substitute
        // APFS defaults and simulators return nil; CI only checks that opening creates a file.
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        _ = try ChatDatabase.open(in: tmpDir)

        let dbURL = tmpDir.appending(path: "chat.sqlite")
        #expect(FileManager.default.fileExists(atPath: dbURL.path))

        #if os(iOS)
        let attrs = try FileManager.default.attributesOfItem(atPath: dbURL.path)
        if let protection = attrs[.protectionKey] as? FileProtectionType {
            #expect(protection == .complete)
        }
        #endif
    }

    @Test func partialUniqueIndexBlocksTwoSelectedRows() async throws {
        let db = try ChatDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let url = URL(string: "https://example.com/v1")!

        try await db.queue.write { db in
            try ModelConfigurationRecord(
                id: "a", name: "A", baseURL: url, apiKeyRef: "ka",
                modelId: "m", createdAt: now, isSelected: true
            ).insert(db)
        }

        await #expect(throws: (any Error).self) {
            try await db.queue.write { db in
                try ModelConfigurationRecord(
                    id: "b", name: "B", baseURL: url, apiKeyRef: "kb",
                    modelId: "m", createdAt: now, isSelected: true
                ).insert(db)
            }
        }

        try await db.queue.write { db in
            try ModelConfigurationRecord(
                id: "c", name: "C", baseURL: url, apiKeyRef: "kc",
                modelId: "m", createdAt: now, isSelected: false
            ).insert(db)
        }
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
        #expect(count == 9)
    }

    @Test func migratedSchemaSnapshot() async throws {
        let db = try ChatDatabase.makeInMemory()
        assertSnapshot(of: db.queue, as: .dumpContent())
    }

    @Test func v5BackfillsPreExistingConversationsAsUser() async throws {
        var migrator = DatabaseMigrator()
        registerChatMigrations(&migrator)
        let queue = try DatabaseQueue()

        try migrator.migrate(queue, upTo: "v4_modelConfigurationKind")

        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO conversation (id, title, createdAt, updatedAt)
                VALUES ('legacy', 'Pre-v5', '2026-01-01 00:00:00', '2026-01-01 00:00:00')
            """)
        }

        try migrator.migrate(queue)

        let kinds = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT kind FROM conversation ORDER BY id")
        }
        #expect(kinds == ["user"])
    }

    @Test func v4BackfillsExistingRowsAsOpenAICompatible() async throws {
        var migrator = DatabaseMigrator()
        registerChatMigrations(&migrator)
        let queue = try DatabaseQueue()

        try migrator.migrate(queue, upTo: "v3_memory")

        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO modelConfiguration
                    (id, name, baseURL, apiKeyRef, modelId, supportsThinking,
                     maxContextTokens, isSelected, createdAt)
                VALUES
                    ('selected', 'Selected legacy model', 'https://api.example.com/v1',
                     'ref-selected', 'thinking-model', 1, 64000, 1, '2026-01-01 00:00:00'),
                    ('unselected', 'Other legacy model', 'https://proxy.example.com/custom',
                     'ref-other', 'plain-model', 0, 16000, 0, '2026-02-03 04:05:06')
            """)
        }

        let legacyColumns = """
            SELECT id, name, baseURL, apiKeyRef, modelId, supportsThinking,
                   maxContextTokens, isSelected, createdAt
            FROM modelConfiguration ORDER BY id
            """
        let before = try queue.read { db in
            try Row.fetchAll(db, sql: legacyColumns)
        }

        try migrator.migrate(queue)

        let after = try queue.read { db in
            try Row.fetchAll(db, sql: legacyColumns)
        }
        #expect(before.count == 2)
        #expect(after == before)
        let kinds = try await queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT kind FROM modelConfiguration ORDER BY id
            """)
        }
        #expect(kinds == ["openAICompatible", "openAICompatible"])
    }

    @Test func v6BackfillsExistingRowsAsNullSearchBackend() async throws {
        var migrator = DatabaseMigrator()
        registerChatMigrations(&migrator)
        let queue = try DatabaseQueue()

        try migrator.migrate(queue, upTo: "v5_conversationKind")
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO modelConfiguration
                    (id, kind, name, baseURL, apiKeyRef, modelId,
                     supportsThinking, maxContextTokens, isSelected, createdAt)
                VALUES
                    ('legacy', 'openAICompatible', 'Pre-v6',
                     'https://api.example.com/v1', 'ref-1', 'gpt', 0, 16000, 0,
                     '2026-01-01 00:00:00')
            """)
        }

        try migrator.migrate(queue)

        let backends = try await queue.read { db in
            try Optional<String>.fetchAll(db, sql: """
                SELECT searchBackend FROM modelConfiguration ORDER BY id
            """)
        }
        #expect(backends == [nil])
    }

    @Test func searchBackendRoundTripsThroughRecord() async throws {
        let db = try ChatDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let url = URL(string: "https://example.com/v1")!

        try await db.queue.write { db in
            try ModelConfigurationRecord(
                id: "native", name: "N", baseURL: url, apiKeyRef: "k1",
                modelId: "m", createdAt: now, searchBackend: "native"
            ).insert(db)
            try ModelConfigurationRecord(
                id: "none", name: "X", baseURL: url, apiKeyRef: "k2",
                modelId: "m", createdAt: now
            ).insert(db)
        }

        let fetched = try await db.queue.read { db in
            try ModelConfigurationRecord
                .order(Column("id"))
                .fetchAll(db)
        }
        #expect(fetched.map(\.searchBackend) == ["native", nil])
    }

    // Legacy unsigned thinking is unreplayable and must fall back to thinking-off.
    @Test func v8BackfillsExistingRowsAsNullThinkingSignature() async throws {
        var migrator = DatabaseMigrator()
        registerChatMigrations(&migrator)
        let queue = try DatabaseQueue()
        try migrator.migrate(queue, upTo: "v7_toolCallSignature")

        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO conversation (id, title, createdAt, updatedAt)
                VALUES ('c1', 't', '2026-01-01 00:00:00', '2026-01-01 00:00:00')
            """)
            try db.execute(sql: """
                INSERT INTO message (id, conversationId, role, content, createdAt)
                VALUES ('m1', 'c1', 'assistant', 'pre-v8 row', '2026-01-01 00:00:00')
            """)
        }
        try migrator.migrate(queue)

        let fetched = try await queue.read { db in
            try MessageRecord.fetchOne(db, key: "m1")
        }
        #expect(fetched?.thinkingSignature == nil)
        #expect(fetched?.content == "pre-v8 row")
    }

    @Test func thinkingSignatureRoundTripsThroughRecord() async throws {
        let db = try ChatDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try await db.queue.write { db in
            try db.execute(sql: """
                INSERT INTO conversation (id, title, createdAt, updatedAt)
                VALUES ('c1', 't', '2026-01-01 00:00:00', '2026-01-01 00:00:00')
            """)
            try MessageRecord(
                id: "signed", conversationId: "c1", role: .assistant,
                content: "answer", thinkingContent: "trace",
                thinkingDurationMs: 12, thinkingSignature: "sig-1",
                thinkingModelId: "claude-opus-4-7",
                createdAt: now
            ).insert(db)
            try MessageRecord(
                id: "unsigned", conversationId: "c1", role: .assistant,
                content: "answer", createdAt: now
            ).insert(db)
        }

        let fetched = try await db.queue.read { db in
            try MessageRecord.order(Column("id")).fetchAll(db)
        }
        #expect(fetched.map(\.thinkingSignature) == ["sig-1", nil])
        #expect(fetched.map(\.thinkingModelId) == ["claude-opus-4-7", nil])
    }

    @Test func v10FlipsOnlyDefaultAnthropicShimRow() async throws {
        var migrator = DatabaseMigrator()
        registerChatMigrations(&migrator)
        let queue = try DatabaseQueue()
        try migrator.migrate(queue, upTo: "v9_messageThinkingModelId")

        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO modelConfiguration
                    (id, kind, name, baseURL, apiKeyRef, modelId,
                     supportsThinking, maxContextTokens, isSelected, createdAt)
                VALUES
                    ('shim', 'openAICompatible', 'Anthropic',
                     'https://api.anthropic.com/v1/openai/', 'k1',
                     'claude-opus-4-7', 1, 1000000, 0, '2026-01-01 00:00:00')
            """)
            try db.execute(sql: """
                INSERT INTO modelConfiguration
                    (id, kind, name, baseURL, apiKeyRef, modelId,
                     supportsThinking, maxContextTokens, isSelected, createdAt)
                VALUES
                    ('native', 'anthropicNative', 'Anthropic (search)',
                     'https://api.anthropic.com/v1', 'k2',
                     'claude-opus-4-7', 1, 1000000, 0, '2026-01-01 00:00:00')
            """)
            try db.execute(sql: """
                INSERT INTO modelConfiguration
                    (id, kind, name, baseURL, apiKeyRef, modelId,
                     supportsThinking, maxContextTokens, isSelected, createdAt)
                VALUES
                    ('openai', 'openAICompatible', 'OpenAI',
                     'https://api.openai.com/v1', 'k3', 'gpt-5.5',
                     1, 1000000, 0, '2026-01-01 00:00:00')
            """)
            // Custom proxy endpoints must survive the default-shim migration.
            try db.execute(sql: """
                INSERT INTO modelConfiguration
                    (id, kind, name, baseURL, apiKeyRef, modelId,
                     supportsThinking, maxContextTokens, isSelected, createdAt)
                VALUES
                    ('proxy', 'openAICompatible', 'Anthropic via proxy',
                     'https://proxy.example.com/anthropic/v1/openai/', 'k4',
                     'claude-opus-4-7', 1, 1000000, 0, '2026-01-01 00:00:00')
            """)
        }

        try migrator.migrate(queue)

        let rows = try await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, kind, baseURL FROM modelConfiguration ORDER BY id
            """).map { ($0["id"] as String, $0["kind"] as String, $0["baseURL"] as String) }
        }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.0, ($0.1, $0.2)) })

        #expect(byID["shim"]?.0 == "anthropicNative")
        #expect(byID["shim"]?.1 == "https://api.anthropic.com/v1")
        #expect(byID["native"]?.0 == "anthropicNative")
        #expect(byID["native"]?.1 == "https://api.anthropic.com/v1")
        #expect(byID["openai"]?.0 == "openAICompatible")
        #expect(byID["openai"]?.1 == "https://api.openai.com/v1")
        #expect(byID["proxy"]?.0 == "openAICompatible")
        #expect(byID["proxy"]?.1 == "https://proxy.example.com/anthropic/v1/openai/")
    }

    // A signature without its originating model remains unreplayable.
    @Test func v9BackfillsExistingRowsAsNullThinkingModelId() async throws {
        var migrator = DatabaseMigrator()
        registerChatMigrations(&migrator)
        let queue = try DatabaseQueue()
        try migrator.migrate(queue, upTo: "v8_messageThinkingSignature")

        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO conversation (id, title, createdAt, updatedAt)
                VALUES ('c1', 't', '2026-01-01 00:00:00', '2026-01-01 00:00:00')
            """)
            try db.execute(sql: """
                INSERT INTO message (id, conversationId, role, content, createdAt, thinkingSignature)
                VALUES ('m1', 'c1', 'assistant', 'pre-v9 row', '2026-01-01 00:00:00', 'sig-orphan')
            """)
        }
        try migrator.migrate(queue)

        let fetched = try await queue.read { db in
            try MessageRecord.fetchOne(db, key: "m1")
        }
        #expect(fetched?.thinkingModelId == nil)
        #expect(fetched?.thinkingSignature == "sig-orphan")
    }
}
