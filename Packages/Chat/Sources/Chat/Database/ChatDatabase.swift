import Foundation
import GRDB

/// Owns the Chat applet's `DatabaseQueue` (`chat.sqlite`) and the schema
/// migrator.
///
/// Construct one of these at applet activation and pass it to repositories.
/// Tests use `ChatDatabase.makeInMemory()` to get a fully-migrated queue
/// with no on-disk footprint.
public struct ChatDatabase: Sendable {
    public let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// Open the on-disk database at `chat.sqlite` under `directory`,
    /// applying all pending migrations before returning.
    public static func open(in directory: URL) throws -> ChatDatabase {
        let url = directory.appending(path: "chat.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try migrator().migrate(queue)
        return ChatDatabase(queue: queue)
    }

    /// Build a fresh in-memory queue with the migrator applied. Intended
    /// for tests, previews, and headless tooling.
    public static func makeInMemory() throws -> ChatDatabase {
        let queue = try DatabaseQueue()
        try migrator().migrate(queue)
        return ChatDatabase(queue: queue)
    }

    /// The migrator used by both the on-disk and in-memory factories.
    /// Exposed so callers that own their own `DatabaseQueue` (e.g. a
    /// future shared-DB scenario) can apply Chat's schema themselves.
    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerChatMigrations(&migrator)
        return migrator
    }
}

/// Register every Chat schema migration in order. Always call this against
/// a fresh `DatabaseMigrator` — appending new migrations is safe; reordering
/// or removing one already applied to a user's database is not.
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
        // Partial unique index makes the "at most one selected row"
        // invariant a schema-level law, not a repo promise. SQLite filters
        // the index to rows matching the WHERE, so any second `isSelected
        // = 1` row throws a UNIQUE constraint violation.
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
}
