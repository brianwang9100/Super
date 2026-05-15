import Foundation
import GRDB

/// Owns the Todo applet's `DatabaseQueue` (`todo.sqlite`) and the schema
/// migrator. Construct one at applet activation and pass it to
/// repositories; tests use `makeInMemory()` for a fully-migrated queue
/// with no on-disk footprint.
public struct TodoDatabase: Sendable {
    public let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// Open the on-disk database at `todo.sqlite` under `directory`,
    /// applying all pending migrations before returning. `.complete` file
    /// protection mirrors Chat — see `docs/SECURITY.md` for the policy. On
    /// macOS (where `swift test` runs) the protection key is a best-effort
    /// no-op.
    public static func open(
        in directory: URL,
        fileProtection: FileProtectionType = .complete
    ) throws -> TodoDatabase {
        let url = directory.appending(path: "todo.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try migrator().migrate(queue)
        try? FileManager.default.setAttributes(
            [.protectionKey: fileProtection],
            ofItemAtPath: url.path
        )
        return TodoDatabase(queue: queue)
    }

    /// Build a fresh in-memory queue with the migrator applied. Intended
    /// for tests, previews, and headless tooling.
    public static func makeInMemory() throws -> TodoDatabase {
        let queue = try DatabaseQueue()
        try migrator().migrate(queue)
        return TodoDatabase(queue: queue)
    }

    /// The migrator used by both the on-disk and in-memory factories. In
    /// DEBUG `eraseDatabaseOnSchemaChange = true` so in-development column
    /// additions land without a separate migration. Release builds never
    /// do this — once a schema ships to a device, every change must be a
    /// new migration.
    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        registerTodoMigrations(&migrator)
        return migrator
    }
}
