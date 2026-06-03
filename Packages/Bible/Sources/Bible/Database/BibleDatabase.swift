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

    migrator.registerMigration("v4_createNote") { db in
        // Polymorphic single table mirroring `bibleAnnotation` — `target`
        // discriminates the three scopes (book / chapter / verse), and the
        // position columns are nullable because lower-precision targets don't
        // carry them. Notes differ from annotations in two ways: there is no
        // `kind`/`title` (a note is just free-text `body`), and rows carry an
        // `updatedAt` because notes are edited in place rather than
        // regenerated wholesale. `source` is 'user' or 'assistant'; `modelId`
        // is nullable (set only for assistant-written notes). Multi-row per
        // target group is deliberate — each row is one card in the list sheet.
        try db.create(table: "bibleNote") { t in
            t.primaryKey("id", .text)
            t.column("target", .text).notNull()
            t.column("bookId", .text).notNull()
            t.column("chapterNumber", .integer)
            t.column("verseStart", .integer)
            t.column("verseEnd", .integer)
            t.column("body", .text).notNull()
            t.column("source", .text).notNull()
            t.column("modelId", .text)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
        // Reader's `@Query` slice — `verseEnd` is the lead axis for grouping
        // note glyphs after the last verse of each note's range. The leading
        // `(bookId, chapterNumber)` also satisfies chapter-scope lookups, so a
        // single index covers both per-chapter listing and per-verse
        // positioning. Mirrors `bibleAnnotation_on_bookId_chapterNumber_verseEnd`.
        try db.create(
            index: "bibleNote_on_bookId_chapterNumber_verseEnd",
            on: "bibleNote",
            columns: ["bookId", "chapterNumber", "verseEnd"]
        )
        // Book-picker glyph visibility — "does this book carry any note at any
        // level?" resolves to a DISTINCT bookId over this index.
        try db.create(
            index: "bibleNote_on_target_bookId",
            on: "bibleNote",
            columns: ["target", "bookId"]
        )
    }

    migrator.registerMigration("v5_annotationCategory") { db in
        // Replace the free-form `kind` (text/reference) flag with a semantic
        // `category` (Int-backed `BibleAnnotationCategory`) that is the single
        // source of truth for both card ordering and rendering.
        //
        // Destructive by design: pre-existing annotation rows were generated
        // before the category distinction existed, so there is no recoverable
        // semantic category to backfill. Annotations are cheap, local-only,
        // and regenerated on next view, so we drop and rebuild the table
        // rather than invent a sentinel "uncategorized" bucket.
        try db.execute(sql: "DROP TABLE bibleAnnotation")
        try db.create(table: "bibleAnnotation") { t in
            t.primaryKey("id", .text)
            t.column("target", .text).notNull()
            t.column("bookId", .text).notNull()
            t.column("chapterNumber", .integer)
            t.column("verseStart", .integer)
            t.column("verseEnd", .integer)
            // CHECK guards the `BibleAnnotationCategory` raw-value range:
            // an out-of-range integer (a corrupt write, a direct DB edit, a
            // future sync payload from a newer build) is rejected at insert
            // time rather than throwing in GRDB's row decoder on read — where
            // `@Query` would swallow it as `defaultValue: []` and blank every
            // card. Widen this bound in lockstep when a category is added.
            t.column("category", .integer).notNull().check { $0 >= 1 && $0 <= 5 }
            t.column("title", .text).notNull()
            t.column("body", .text).notNull()
            t.column("source", .text).notNull()
            t.column("modelId", .text).notNull()
            t.column("createdAt", .datetime).notNull()
        }
        // Recreate the two indexes dropped with the table — see v3 for the
        // access patterns each one serves.
        try db.create(
            index: "bibleAnnotation_on_bookId_chapterNumber_verseEnd",
            on: "bibleAnnotation",
            columns: ["bookId", "chapterNumber", "verseEnd"]
        )
        try db.create(
            index: "bibleAnnotation_on_target_bookId",
            on: "bibleAnnotation",
            columns: ["target", "bookId"]
        )
    }

    migrator.registerMigration("v6_createBulkAnnotationLedger") { db in
        // Durable ledger for the bulk-annotation runner. `bulkAnnotationRun`
        // is one row per kicked-off job; `bulkAnnotationRunUnit` is one row per
        // unit (a chapter, or a book prologue) with a cascading FK so deleting
        // a run clears its units. Annotation *content* still lives in
        // `bibleAnnotation` (stamped `source: .userBulk`) — this ledger only
        // tracks run/unit progress so a run can resume, retry, and report.
        try db.create(table: "bulkAnnotationRun") { t in
            t.primaryKey("id", .text)
            // BulkRunStatus: running | paused | completed | failed | cancelled.
            t.column("status", .text).notNull()
            // Model active at kickoff — stamped onto the rows the run produces.
            t.column("modelId", .text).notNull()
            // BulkRunHaltReason — set only when status == failed (circuit breaker).
            t.column("haltReason", .text)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            // Set only on a terminal status — drives the Completed section and
            // the 24 h sweep cutoff.
            t.column("completedAt", .datetime)
            // Invariant: completedAt is non-null exactly when the run is
            // terminal (completed / failed / cancelled) and null while it's
            // active (running / paused). Enforced at the schema so an engine
            // bug — marking a run done without stamping completedAt, or vice
            // versa — fails loudly at write rather than silently breaking the
            // Completed section / 24 h sweep. SQLite can't ADD CONSTRAINT after
            // the table ships, so it's declared up front; widen the status list
            // in lockstep if a terminal status is added (cf. the category CHECK
            // on bibleAnnotation).
            t.check(sql: "(status IN ('completed', 'failed', 'cancelled')) = (completedAt IS NOT NULL)")
        }
        // "Is there an active run?" (status IN running|paused) and the
        // Completed-section filter both restrict on status.
        try db.create(
            index: "bulkAnnotationRun_on_status",
            on: "bulkAnnotationRun",
            columns: ["status"]
        )
        // The 24 h sweep ranges on completedAt.
        try db.create(
            index: "bulkAnnotationRun_on_completedAt",
            on: "bulkAnnotationRun",
            columns: ["completedAt"]
        )

        try db.create(table: "bulkAnnotationRunUnit") { t in
            t.primaryKey("id", .text)
            t.column("runId", .text)
                .notNull()
                .references("bulkAnnotationRun", onDelete: .cascade)
            // Stable run / queue order within the run.
            t.column("ordinal", .integer).notNull()
            // BulkRunUnitKind: chapter | bookPrologue.
            t.column("kind", .text).notNull()
            t.column("bookId", .text).notNull()
            // Denormalized so a run renders its title without a catalog lookup.
            t.column("bookName", .text).notNull()
            // Null for bookPrologue units.
            t.column("chapterNumber", .integer)
            // BulkUnitState: queued | generating | done | failed.
            t.column("state", .text).notNull()
            t.column("attemptCount", .integer).notNull().defaults(to: 0)
            t.column("producedCount", .integer).notNull().defaults(to: 0)
            t.column("errorMessage", .text)
            t.column("updatedAt", .datetime).notNull()
        }
        // Ordered per-run fetch — the engine and the snapshot read units by
        // run in ordinal order.
        try db.create(
            index: "bulkAnnotationRunUnit_on_runId_ordinal",
            on: "bulkAnnotationRunUnit",
            columns: ["runId", "ordinal"]
        )
    }
}
