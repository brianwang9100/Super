import Foundation
import GRDB

public struct ChatDatabase: Sendable {
    public let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// Applies `.complete` file protection by default because conversation history
    /// does not need to be readable while the device is locked. The attribute is
    /// best-effort on platforms that do not enforce data protection.
    public static func open(
        in directory: URL,
        fileProtection: FileProtectionType = .complete
    ) throws -> ChatDatabase {
        let url = directory.appending(path: "chat.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try migrator().migrate(queue)
        try? FileManager.default.setAttributes(
            [.protectionKey: fileProtection],
            ofItemAtPath: url.path
        )
        return ChatDatabase(queue: queue)
    }

    public static func makeInMemory() throws -> ChatDatabase {
        let queue = try DatabaseQueue()
        try migrator().migrate(queue)
        return ChatDatabase(queue: queue)
    }

    /// Debug builds may erase incompatible development schemas; release builds
    /// require append-only migrations.
    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        registerChatMigrations(&migrator)
        return migrator
    }
}

/// Migration order is persistent API: append new migrations without reordering old ones.
public func registerChatMigrations(_ migrator: inout DatabaseMigrator) {

    migrator.registerMigration("v1_createTables") { db in

        try db.create(table: "conversation") { t in
            t.primaryKey("id", .text)
            t.column("title", .text)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("deletedAt", .datetime)
        }
        try db.create(
            index: "conversation_on_updatedAt",
            on: "conversation",
            columns: ["updatedAt"]
        )

        try db.create(table: "message") { t in
            t.primaryKey("id", .text)
            t.column("conversationId", .text).notNull()
                .references("conversation", onDelete: .cascade)
            t.column("role", .text).notNull()
            t.column("content", .text).notNull()
            t.column("thinkingContent", .text)
            t.column("thinkingDurationMs", .integer)
            t.column("toolCallId", .text)
            t.column("createdAt", .datetime).notNull()
            t.column("tokenCount", .integer)
        }
        try db.create(
            index: "message_on_conversationId_createdAt",
            on: "message",
            columns: ["conversationId", "createdAt"]
        )

        try db.create(table: "toolCall") { t in
            t.primaryKey("id", .text)
            t.column("messageId", .text).notNull()
                .references("message", onDelete: .cascade)
            t.column("conversationId", .text).notNull()
            t.column("toolName", .text).notNull()
            t.column("parameters", .text).notNull()
            t.column("result", .text)
            t.column("status", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("completedAt", .datetime)
        }
        try db.create(
            index: "toolCall_on_conversationId",
            on: "toolCall",
            columns: ["conversationId"]
        )
        try db.create(
            index: "toolCall_on_messageId",
            on: "toolCall",
            columns: ["messageId"]
        )
        try db.create(
            index: "toolCall_on_status",
            on: "toolCall",
            columns: ["status"]
        )

        try db.create(table: "modelConfiguration") { t in
            t.primaryKey("id", .text)
            t.column("name", .text).notNull()
            t.column("baseURL", .text).notNull()
            t.column("apiKeyRef", .text).notNull()
            t.column("modelId", .text).notNull()
            t.column("supportsThinking", .boolean).notNull().defaults(to: false)
            t.column("maxContextTokens", .integer).notNull()
            t.column("isSelected", .boolean).notNull().defaults(to: false)
            t.column("createdAt", .datetime).notNull()
        }
        try db.execute(sql: """
            CREATE UNIQUE INDEX modelConfiguration_unique_selected
            ON modelConfiguration(isSelected) WHERE isSelected = 1
        """)

        try db.create(table: "toolEnablement") { t in
            t.primaryKey("toolId", .text)
            t.column("isEnabled", .boolean).notNull()
        }

        try db.create(table: "setting") { t in
            t.primaryKey("key", .text)
            t.column("value", .text).notNull()
        }

        try db.create(table: "compactionCheckpoint") { t in
            t.primaryKey("id", .text)
            t.column("conversationId", .text).notNull()
                .references("conversation", onDelete: .cascade)
            t.column("uptoMessageId", .text).notNull()
            t.column("summary", .text).notNull()
            t.column("tokensBefore", .integer).notNull()
            t.column("tokensAfter", .integer).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("isLive", .boolean).notNull()
        }
        try db.create(
            index: "compactionCheckpoint_on_conversationId_isLive",
            on: "compactionCheckpoint",
            columns: ["conversationId", "isLive"]
        )
    }

    migrator.registerMigration("v2_messageAttachments") { db in
        try db.alter(table: "message") { t in
            t.add(column: "attachmentsJSON", .text)
        }
    }

    migrator.registerMigration("v3_memory") { db in
        try db.create(table: "memory") { t in
            t.primaryKey("id", .text)
            t.column("text", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
        try db.create(
            index: "memory_on_createdAt",
            on: "memory",
            columns: ["createdAt"]
        )
    }

    // SQLite requires rebuilding the table to relax the URL and key constraints.
    migrator.registerMigration("v4_modelConfigurationKind") { db in
        // Match GRDB's quoted sqlite_master representation.
        try db.execute(sql: "CREATE TABLE \"modelConfiguration_new\" (\"id\" TEXT PRIMARY KEY NOT NULL, \"kind\" TEXT NOT NULL DEFAULT 'openAICompatible', \"name\" TEXT NOT NULL, \"baseURL\" TEXT, \"apiKeyRef\" TEXT, \"modelId\" TEXT NOT NULL, \"supportsThinking\" BOOLEAN NOT NULL DEFAULT 0, \"maxContextTokens\" INTEGER NOT NULL, \"isSelected\" BOOLEAN NOT NULL DEFAULT 0, \"createdAt\" DATETIME NOT NULL)")
        try db.execute(sql: """
            INSERT INTO modelConfiguration_new
                (id, kind, name, baseURL, apiKeyRef, modelId,
                 supportsThinking, maxContextTokens, isSelected, createdAt)
            SELECT
                id, 'openAICompatible', name, baseURL, apiKeyRef, modelId,
                supportsThinking, maxContextTokens, isSelected, createdAt
            FROM modelConfiguration
        """)
        try db.execute(sql: "DROP TABLE modelConfiguration")
        try db.execute(sql: "ALTER TABLE modelConfiguration_new RENAME TO modelConfiguration")
        try db.execute(sql: """
            CREATE UNIQUE INDEX modelConfiguration_unique_selected
            ON modelConfiguration(isSelected) WHERE isSelected = 1
        """)
    }

    migrator.registerMigration("v5_conversationKind") { db in
        try db.alter(table: "conversation") { t in
            t.add(column: "kind", .text).notNull().defaults(to: "user")
        }
    }

    migrator.registerMigration("v6_searchBackend") { db in
        try db.alter(table: "modelConfiguration") { t in
            t.add(column: "searchBackend", .text)
        }
    }

    // Gemini rejects tool continuations unless its opaque thought signature is replayed.
    migrator.registerMigration("v7_toolCallSignature") { db in
        try db.alter(table: "toolCall") { t in
            t.add(column: "signature", .text)
        }
    }

    // Anthropic rejects tool continuations unless signed thinking is replayed verbatim.
    migrator.registerMigration("v8_messageThinkingSignature") { db in
        try db.alter(table: "message") { t in
            t.add(column: "thinkingSignature", .text)
        }
    }

    // Anthropic thinking signatures are model-specific and must not survive a model switch.
    migrator.registerMigration("v9_messageThinkingModelId") { db in
        try db.alter(table: "message") { t in
            t.add(column: "thinkingModelId", .text)
        }
    }

    // Match the exact legacy default URL so custom Anthropic proxies remain unchanged.
    migrator.registerMigration("v10_anthropicNativeDefault") { db in
        try db.execute(
            sql: """
            UPDATE modelConfiguration
            SET kind = 'anthropicNative', baseURL = 'https://api.anthropic.com/v1'
            WHERE kind = 'openAICompatible' AND baseURL = 'https://api.anthropic.com/v1/openai/'
            """
        )
    }
    // Explicit company identity; protocol compatibility never opts existing credentials into audio.
    migrator.registerMigration("v11_modelProviderIdentity") { db in
        try db.execute(sql: "ALTER TABLE modelConfiguration ADD COLUMN providerId TEXT")
    }

    migrator.registerMigration("v12_modelStagedKey") { db in
        try db.execute(sql: """
            CREATE TABLE modelStagedKey (
                id TEXT PRIMARY KEY NOT NULL
            )
            """)
    }
}
