import Foundation
import GRDB

/// Owns the Bible applet's `DatabaseQueue` (`bible.sqlite`) and the schema
/// migrator.
///
/// Construct one at applet activation and pass it to repositories. Tests use
/// `BibleDatabase.makeInMemory()` for a fully-migrated queue with no on-disk
/// footprint. A single-writer `DatabaseQueue` is enough — the applet has no
/// concurrent-write workload.
public struct BibleDatabase: Sendable {
    public let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// Open the on-disk database at `bible.sqlite` under `directory`,
    /// applying all pending migrations before returning.
    ///
    /// The bundled scripture is public-domain text, but the reader's
    /// position is mildly personal, so the SQLite file inherits the
    /// `.complete` file-protection class per `docs/SECURITY.md`. The
    /// attribute is iOS-enforced; macOS test runs silently no-op it.
    public static func open(
        in directory: URL,
        fileProtection: FileProtectionType = .complete
    ) throws -> BibleDatabase {
        let url = directory.appending(path: "bible.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try migrator().migrate(queue)
        try? FileManager.default.setAttributes(
            [.protectionKey: fileProtection],
            ofItemAtPath: url.path
        )
        return BibleDatabase(queue: queue)
    }

    /// Build a fresh in-memory queue with the migrator applied. Intended
    /// for tests, previews, and headless tooling.
    public static func makeInMemory() throws -> BibleDatabase {
        let queue = try DatabaseQueue()
        try migrator().migrate(queue)
        return BibleDatabase(queue: queue)
    }

    /// The migrator used by both factories.
    ///
    /// In DEBUG builds `eraseDatabaseOnSchemaChange` is set so in-progress
    /// schema edits land without a separate migration. Release builds never
    /// erase — once a schema ships, every change must be a new migration.
    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        registerBibleMigrations(&migrator)
        return migrator
    }
}

/// Register every Bible schema migration in order. Appending new migrations
/// is safe; reordering or removing one already applied to a user's database
/// is not.
public func registerBibleMigrations(_ migrator: inout DatabaseMigrator) {

    migrator.registerMigration("v1_createReadingPosition") { db in
        try db.create(table: "bibleReadingPosition") { t in
            t.primaryKey("id", .text)
            t.column("bookId", .text).notNull()
            t.column("chapterNumber", .integer).notNull()
            t.column("translationId", .text).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
    }

    migrator.registerMigration("v2_createHighlight") { db in
        try db.create(table: "bibleHighlight") { t in
            t.primaryKey("id", .text)
            t.column("bookId", .text).notNull()
            t.column("chapterNumber", .integer).notNull()
            t.column("verseNumber", .integer).notNull()
            t.column("colorId", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("deletedAt", .datetime)
        }
        // The chapter renderer's `@Query` fetches every active highlight for
        // one (book, chapter); the soft-delete index keeps that filter and the
        // re-highlight lookup off a table scan.
        try db.create(
            index: "bibleHighlight_on_bookId_chapterNumber",
            on: "bibleHighlight",
            columns: ["bookId", "chapterNumber"]
        )
        try db.create(
            index: "bibleHighlight_on_deletedAt",
            on: "bibleHighlight",
            columns: ["deletedAt"]
        )
    }
}
