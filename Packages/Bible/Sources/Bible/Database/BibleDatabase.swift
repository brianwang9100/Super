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
        // One row per (book, chapter, verse) — active or cleared — is a hard
        // invariant the repository's read-then-upsert relies on; a UNIQUE
        // index enforces it at the database so a future concurrent writer
        // fails loudly instead of silently duplicating a verse. Its leading
        // (bookId, chapterNumber) columns also serve the chapter renderer's
        // `@Query`. The soft-delete index keeps the active-only filter off a
        // table scan.
        try db.create(
            index: "bibleHighlight_on_bookId_chapterNumber_verseNumber",
            on: "bibleHighlight",
            columns: ["bookId", "chapterNumber", "verseNumber"],
            unique: true
        )
        try db.create(
            index: "bibleHighlight_on_deletedAt",
            on: "bibleHighlight",
            columns: ["deletedAt"]
        )
    }

    migrator.registerMigration("v3_createAnnotation") { db in
        // Polymorphic single table — `target` discriminates the three
        // scopes (book / chapter / verse). Position columns are nullable
        // because lower-precision targets don't carry them: `.book` rows
        // have only `bookId` set, `.chapter` rows add `chapterNumber`,
        // `.verse` rows fill all three position columns (`verseEnd` equals
        // `verseStart` for single-verse annotations). Multi-row per target
        // group is deliberate — each row is one card in the popover. No
        // UNIQUE constraint on the position tuple; uniqueness is by row id
        // only.
        try db.create(table: "bibleAnnotation") { t in
            t.primaryKey("id", .text)
            t.column("target", .text).notNull()
            t.column("bookId", .text).notNull()
            t.column("chapterNumber", .integer)
            t.column("verseStart", .integer)
            t.column("verseEnd", .integer)
            t.column("kind", .text).notNull()
            t.column("title", .text).notNull()
            t.column("body", .text).notNull()
            t.column("source", .text).notNull()
            t.column("modelId", .text).notNull()
            t.column("createdAt", .datetime).notNull()
        }
        // Chapter renderer's `@Query` slice — `verseEnd` is the lead axis
        // for grouping bubbles after the last verse of each annotation
        // range. The leading `(bookId, chapterNumber)` also satisfies
        // chapter-scope lookups, so a single index covers both per-chapter
        // listing and per-verse positioning.
        try db.create(
            index: "bibleAnnotation_on_bookId_chapterNumber_verseEnd",
            on: "bibleAnnotation",
            columns: ["bookId", "chapterNumber", "verseEnd"]
        )
        // Book-picker bubble visibility — "does this book have any
        // annotations at any level?" boils down to "is there a row whose
        // bookId == X?"; restricting on `target` is not necessary because
        // any annotation (book, chapter, or verse) makes the book "carry
        // notes." Keeping `target` in the index leaves room to switch the
        // book bubble's semantics later (e.g. light book bubble only when
        // a book-target row exists) without a second index.
        try db.create(
            index: "bibleAnnotation_on_target_bookId",
            on: "bibleAnnotation",
            columns: ["target", "bookId"]
        )
    }
}
