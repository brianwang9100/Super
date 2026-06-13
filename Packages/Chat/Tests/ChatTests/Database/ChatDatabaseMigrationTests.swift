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

    @Test func openAppliesFileProtectionToOnDiskDatabase() throws {
        // .complete file-protection is enforced only on iOS hardware.
        // The FileManager readback is unreliable elsewhere:
        //   - macOS local: nil
        //   - macOS runner (GitHub): .completeUntilFirstUserAuthentication
        //     (APFS default substituted when .complete isn't supported)
        //   - iOS simulator: nil (sim doesn't honor data protection)
        //   - iOS hardware: .complete
        // So: gate the assertion on iOS to skip macOS, then guard on
        // non-nil readback to skip the simulator. The assertion fires
        // only on real device — in CI this is a smoke test that the
        // open path produces a file.
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
            "memory",
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
            "memory_on_createdAt",
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

        // The second insert with isSelected = false must succeed — the
        // partial index only constrains isSelected = 1 rows.
        try await db.queue.write { db in
            try ModelConfigurationRecord(
                id: "c", name: "C", baseURL: url, apiKeyRef: "kc",
                modelId: "m", createdAt: now, isSelected: false
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
        #expect(lookup["thinkingContent"]?.0 == "TEXT")
        #expect(lookup["thinkingContent"]?.1 == 0)
        #expect(lookup["thinkingDurationMs"]?.0 == "INTEGER")
        #expect(lookup["thinkingDurationMs"]?.1 == 0)
        #expect(lookup["thinkingSignature"]?.0 == "TEXT")
        #expect(lookup["thinkingSignature"]?.1 == 0)
        #expect(lookup["thinkingModelId"]?.0 == "TEXT")
        #expect(lookup["thinkingModelId"]?.1 == 0)
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
        #expect(count == 8)
    }

    /// End-to-end snapshot of the schema after *all* migrations have run
    /// (currently through `v9_messageThinkingModelId`) via
    /// `GRDBSnapshotTesting`. Catches column-type drift, FK clauses, and
    /// DEFAULT expressions that the targeted PRAGMA assertions don't
    /// cover. Snapshot files land under
    /// `Tests/ChatTests/Database/__Snapshots__/`.
    @Test func migratedSchemaSnapshot() async throws {
        let db = try ChatDatabase.makeInMemory()
        assertSnapshot(of: db.queue, as: .dumpContent())
    }

    /// `v4_modelConfigurationKind` adds the `kind` discriminator and
    /// relaxes the NOT NULL constraints on `baseURL` and `apiKeyRef`.
    @Test func v4AddsKindColumnAndNullableURLAndKeyRef() async throws {
        let db = try ChatDatabase.makeInMemory()
        let columns = try await db.queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(modelConfiguration)")
                .map { ($0["name"] as String, $0["type"] as String, $0["notnull"] as Int) }
        }
        let lookup = Dictionary(uniqueKeysWithValues: columns.map { ($0.0, ($0.1, $0.2)) })

        #expect(lookup["kind"]?.0 == "TEXT")
        #expect(lookup["kind"]?.1 == 1)   // NOT NULL
        #expect(lookup["baseURL"]?.0 == "TEXT")
        #expect(lookup["baseURL"]?.1 == 0)   // nullable
        #expect(lookup["apiKeyRef"]?.0 == "TEXT")
        #expect(lookup["apiKeyRef"]?.1 == 0)   // nullable
        // The "at most one selected row" partial unique index is preserved
        // across the recreate-and-copy migration.
        let indexNames = try await db.queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='index' AND tbl_name='modelConfiguration'
            """)
        }
        #expect(indexNames.contains("modelConfiguration_unique_selected"))
    }

    /// `v5_conversationKind` adds the `kind` discriminator column to
    /// the `conversation` table with `NOT NULL DEFAULT 'user'`. Pre-v5
    /// rows backfill via the default — verified with the same
    /// stop-at-prior-version + seed pattern used for v4.
    @Test func v5AddsConversationKindWithUserDefault() async throws {
        let db = try ChatDatabase.makeInMemory()
        let columns = try await db.queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(conversation)")
                .map { ($0["name"] as String, $0["type"] as String, $0["notnull"] as Int, $0["dflt_value"] as String?) }
        }
        let lookup = Dictionary(uniqueKeysWithValues: columns.map { ($0.0, ($0.1, $0.2, $0.3)) })
        #expect(lookup["kind"]?.0 == "TEXT")
        #expect(lookup["kind"]?.1 == 1)
        #expect(lookup["kind"]?.2 == "'user'")
    }

    @Test func v5BackfillsPreExistingConversationsAsUser() async throws {
        var migrator = DatabaseMigrator()
        registerChatMigrations(&migrator)
        let queue = try DatabaseQueue()

        // Stop at v4 — the `conversation` table doesn't have `kind` yet.
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

    /// Pre-existing rows are migrated to `kind = 'openAICompatible'` by
    /// the actual v4 backfill INSERT — `DatabaseMigrator.migrate(_:upTo:)`
    /// lets the test stop at v3, seed a pre-v4 row whose schema has no
    /// `kind` column, then apply v4 and assert on the migrated value.
    /// This exercises the literal SELECT clause inside the migration, not
    /// just the recreated column's DEFAULT.
    @Test func v4BackfillsExistingRowsAsOpenAICompatible() async throws {
        var migrator = DatabaseMigrator()
        registerChatMigrations(&migrator)
        let queue = try DatabaseQueue()

        // Stop at v3 — `modelConfiguration` still has the original v1
        // shape (NOT NULL baseURL/apiKeyRef, no `kind` column).
        try migrator.migrate(queue, upTo: "v3_memory")

        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO modelConfiguration
                    (id, name, baseURL, apiKeyRef, modelId, supportsThinking,
                     maxContextTokens, isSelected, createdAt)
                VALUES
                    ('legacy', 'Pre-v4', 'https://api.example.com/v1',
                     'ref-1', 'gpt', 0, 16000, 0, '2026-01-01 00:00:00')
            """)
        }

        // Now apply v4 — the backfill INSERT runs against the seeded row.
        try migrator.migrate(queue)

        let kinds = try await queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT kind FROM modelConfiguration ORDER BY id
            """)
        }
        #expect(kinds == ["openAICompatible"])
    }

    /// `v6_searchBackend` adds a nullable `searchBackend` column without a
    /// table rebuild, so the partial unique index survives untouched.
    @Test func v6AddsNullableSearchBackendColumn() async throws {
        let db = try ChatDatabase.makeInMemory()
        let columns = try await db.queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(modelConfiguration)")
                .map { ($0["name"] as String, $0["type"] as String, $0["notnull"] as Int) }
        }
        let lookup = Dictionary(uniqueKeysWithValues: columns.map { ($0.0, ($0.1, $0.2)) })
        #expect(lookup["searchBackend"]?.0 == "TEXT")
        #expect(lookup["searchBackend"]?.1 == 0)   // nullable

        let indexNames = try await db.queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='index' AND tbl_name='modelConfiguration'
            """)
        }
        #expect(indexNames.contains("modelConfiguration_unique_selected"))
    }

    /// Rows that existed before v6 migrate to `searchBackend = NULL` (no
    /// web search). Stop at v5, seed a row whose schema lacks the column,
    /// apply v6, assert the migrated value.
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

    /// `searchBackend` round-trips through `ModelConfigurationRecord`'s
    /// Codable mapping — both a set value and the nil default persist and
    /// re-fetch unchanged.
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
        // Ordered by id ascending: "native" sorts before "none".
        #expect(fetched.map(\.searchBackend) == ["native", nil])
    }

    /// `v8_messageThinkingSignature` adds a nullable `thinkingSignature`
    /// column to `message` without a table rebuild.
    @Test func v8AddsNullableThinkingSignatureColumn() async throws {
        let db = try ChatDatabase.makeInMemory()
        let columns = try await db.queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(message)")
                .map { ($0["name"] as String, $0["type"] as String, $0["notnull"] as Int) }
        }
        let lookup = Dictionary(uniqueKeysWithValues: columns.map { ($0.0, ($0.1, $0.2)) })
        #expect(lookup["thinkingSignature"]?.0 == "TEXT")
        #expect(lookup["thinkingSignature"]?.1 == 0)   // nullable
    }

    /// Rows that existed before v8 migrate to `thinkingSignature = NULL`
    /// (no replayable thinking block — the Anthropic request gate falls
    /// back to thinking-off for those histories). Stop at v7, seed a row
    /// whose schema lacks the column, apply v8, assert the migrated value.
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
        // Ordered by id ascending: "signed" sorts before "unsigned".
        #expect(fetched.map(\.thinkingSignature) == ["sig-1", nil])
        #expect(fetched.map(\.thinkingModelId) == ["claude-opus-4-7", nil])
    }

    @Test func v9AddsNullableThinkingModelIdColumn() async throws {
        let db = try ChatDatabase.makeInMemory()
        let columns = try await db.queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(message)")
                .map { ($0["name"] as String, $0["type"] as String, $0["notnull"] as Int) }
        }
        let lookup = Dictionary(uniqueKeysWithValues: columns.map { ($0.0, ($0.1, $0.2)) })
        #expect(lookup["thinkingModelId"]?.0 == "TEXT")
        #expect(lookup["thinkingModelId"]?.1 == 0)   // nullable
    }

    /// `v10_anthropicNativeDefault` flips *only* the default Anthropic
    /// OpenAI-compat shim row to native (`kind` + `baseURL`), leaving every
    /// other row untouched: a native-search Anthropic row (already native), a
    /// non-Anthropic provider, and a user's custom-URL Anthropic proxy. Stop at
    /// v9, seed all four, apply v10, assert the selective flip.
    @Test func v10FlipsOnlyDefaultAnthropicShimRow() async throws {
        var migrator = DatabaseMigrator()
        registerChatMigrations(&migrator)
        let queue = try DatabaseQueue()
        try migrator.migrate(queue, upTo: "v9_messageThinkingModelId")

        try await queue.write { db in
            // 1. Default Anthropic shim row — the migration's sole target.
            try db.execute(sql: """
                INSERT INTO modelConfiguration
                    (id, kind, name, baseURL, apiKeyRef, modelId,
                     supportsThinking, maxContextTokens, isSelected, createdAt)
                VALUES
                    ('shim', 'openAICompatible', 'Anthropic',
                     'https://api.anthropic.com/v1/openai/', 'k1',
                     'claude-opus-4-7', 1, 1000000, 0, '2026-01-01 00:00:00')
            """)
            // 2. Native-search Anthropic row — already native, must be left as-is.
            try db.execute(sql: """
                INSERT INTO modelConfiguration
                    (id, kind, name, baseURL, apiKeyRef, modelId,
                     supportsThinking, maxContextTokens, isSelected, createdAt)
                VALUES
                    ('native', 'anthropicNative', 'Anthropic (search)',
                     'https://api.anthropic.com/v1', 'k2',
                     'claude-opus-4-7', 1, 1000000, 0, '2026-01-01 00:00:00')
            """)
            // 3. A non-Anthropic provider — different host, untouched.
            try db.execute(sql: """
                INSERT INTO modelConfiguration
                    (id, kind, name, baseURL, apiKeyRef, modelId,
                     supportsThinking, maxContextTokens, isSelected, createdAt)
                VALUES
                    ('openai', 'openAICompatible', 'OpenAI',
                     'https://api.openai.com/v1', 'k3', 'gpt-5.5',
                     1, 1000000, 0, '2026-01-01 00:00:00')
            """)
            // 4. A custom Anthropic proxy — not the exact default shim URL,
            //    so deliberately preserved (a power user's own endpoint).
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

        // Only the default shim row flipped — kind AND baseURL.
        #expect(byID["shim"]?.0 == "anthropicNative")
        #expect(byID["shim"]?.1 == "https://api.anthropic.com/v1")
        // Everything else byte-identical to what was seeded.
        #expect(byID["native"]?.0 == "anthropicNative")
        #expect(byID["native"]?.1 == "https://api.anthropic.com/v1")
        #expect(byID["openai"]?.0 == "openAICompatible")
        #expect(byID["openai"]?.1 == "https://api.openai.com/v1")
        #expect(byID["proxy"]?.0 == "openAICompatible")
        #expect(byID["proxy"]?.1 == "https://proxy.example.com/anthropic/v1/openai/")
    }

    /// Rows that existed before v9 migrate to `thinkingModelId = NULL` — a
    /// stored signature with no recorded model is treated as unreplayable
    /// (thinking-off fallback). Stop at v8, seed a row, apply v9.
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
