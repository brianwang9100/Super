import Foundation
import GRDB

/// One queue owns mutable user state; bundled scripture uses BibleTextDatabase.
public struct BibleDatabase: Sendable {
    public let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// Opens bible.sqlite and applies pending migrations. File protection is enforced
    /// on iOS; macOS ignores it.
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

    /// Returns a fresh, fully migrated in-memory database.
    public static func makeInMemory() throws -> BibleDatabase {
        let queue = try DatabaseQueue()
        try migrator().migrate(queue)
        return BibleDatabase(queue: queue)
    }

    /// DEBUG may erase after schema changes. Shipped release migrations must remain append-only.
    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        registerBibleMigrations(&migrator)
        return migrator
    }
}

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
        // Active and cleared highlights share one unique verse slot; read-then-upsert relies on it.
        // Leading book/chapter columns also serve chapter decoration queries.
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
        // Targets control nullable position fields. Multiple cards per target are intentional;
        // uniqueness is by row ID, not the position tuple.
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
        // verseEnd anchors each range's bubble; leading book/chapter columns also serve chapter lookup.
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

    migrator.registerMigration("v4_createNote") { db in
        // Targets share the annotation position encoding. Multiple notes per target are intentional.
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
        // verseEnd anchors each range's glyph; leading book/chapter columns also serve chapter lookup.
        try db.create(
            index: "bibleNote_on_bookId_chapterNumber_verseEnd",
            on: "bibleNote",
            columns: ["bookId", "chapterNumber", "verseEnd"]
        )
        try db.create(
            index: "bibleNote_on_target_bookId",
            on: "bibleNote",
            columns: ["target", "bookId"]
        )
    }

    migrator.registerMigration("v5_annotationCategory") { db in
        // Existing cards have no recoverable semantic category. This migration intentionally
        // drops regenerable annotation content instead of inventing an uncategorized value.
        try db.execute(sql: "DROP TABLE bibleAnnotation")
        try db.create(table: "bibleAnnotation") { t in
            t.primaryKey("id", .text)
            t.column("target", .text).notNull()
            t.column("bookId", .text).notNull()
            t.column("chapterNumber", .integer)
            t.column("verseStart", .integer)
            t.column("verseEnd", .integer)
            // Reject invalid categories on write: a row-decoding failure would blank the query result.
            // Widen this bound when adding a category.
            t.column("category", .integer).notNull().check { $0 >= 1 && $0 <= 5 }
            t.column("title", .text).notNull()
            t.column("body", .text).notNull()
            t.column("source", .text).notNull()
            t.column("modelId", .text).notNull()
            t.column("createdAt", .datetime).notNull()
        }
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
        // This ledger tracks resumable progress; annotation content remains in bibleAnnotation.
        try db.create(table: "bulkAnnotationRun") { t in
            t.primaryKey("id", .text)
            t.column("status", .text).notNull()
            // Kickoff metadata; per-annotation provenance comes from the dispatcher.
            t.column("modelId", .text).notNull()
            t.column("haltReason", .text)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("completedAt", .datetime)
            // completedAt exists exactly for terminal runs. Keep this check aligned with new
            // terminal statuses so history and the 24-hour sweep cannot miss finished runs.
            t.check(sql: "(status IN ('completed', 'failed', 'cancelled')) = (completedAt IS NOT NULL)")
        }
        try db.create(
            index: "bulkAnnotationRun_on_status",
            on: "bulkAnnotationRun",
            columns: ["status"]
        )
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
            t.column("ordinal", .integer).notNull()
            t.column("kind", .text).notNull()
            t.column("bookId", .text).notNull()
            // Denormalized so a run renders its title without a catalog lookup.
            t.column("bookName", .text).notNull()
            // Null for bookPrologue units.
            t.column("chapterNumber", .integer)
            // BulkUnitState: queued | generating | done | failed | skipped.
            t.column("state", .text).notNull()
            t.column("attemptCount", .integer).notNull().defaults(to: 0)
            t.column("producedCount", .integer).notNull().defaults(to: 0)
            t.column("errorMessage", .text)
            t.column("updatedAt", .datetime).notNull()
        }
        try db.create(
            index: "bulkAnnotationRunUnit_on_runId_ordinal",
            on: "bulkAnnotationRunUnit",
            columns: ["runId", "ordinal"]
        )
    }

    migrator.registerMigration("v7_bulkRunOverwriteFlag") { db in
        // Existing and resumed runs default to preserving annotations. ADD COLUMN leaves
        // the terminal-status/completedAt constraint intact.
        try db.alter(table: "bulkAnnotationRun") { t in
            t.add(column: "overwriteExisting", .boolean).notNull().defaults(to: false)
        }
    }

    migrator.registerMigration("v8_createBookmark") { db in
        // Hard-delete bookmarks: tombstones would occupy unique color slots and block reuse.
        // Each assignment is a fresh row; future sync must carry deletions separately by colorId.
        // Book/chapter identity is shared across translations.
        try db.create(table: "bibleBookmark") { t in
            t.primaryKey("id", .text)
            t.column("colorId", .text).notNull()
            t.column("bookId", .text).notNull()
            t.column("chapterNumber", .integer).notNull()
            t.column("createdAt", .datetime).notNull()
        }
        // Enforce one color per chapter and one chapter per color even outside repository toggles.
        try db.create(
            index: "bibleBookmark_on_colorId",
            on: "bibleBookmark",
            columns: ["colorId"],
            unique: true
        )
        try db.create(
            index: "bibleBookmark_on_bookId_chapterNumber",
            on: "bibleBookmark",
            columns: ["bookId", "chapterNumber"],
            unique: true
        )
    }

    migrator.registerMigration("v9_annotationSummary") { db in
        // Multi-card annotations cannot be mapped faithfully to the new single-summary contract,
        // so regenerate them. Clear the ledger too: its done units would otherwise claim
        // annotations still exist. Delete units explicitly because migrations disable foreign
        // keys, preventing ON DELETE CASCADE and leaving orphans for the final FK check.
        try db.execute(sql: "DELETE FROM bulkAnnotationRunUnit")
        try db.execute(sql: "DELETE FROM bulkAnnotationRun")
        try db.execute(sql: "DROP TABLE bibleAnnotation")
        try db.create(table: "bibleAnnotation") { t in
            t.primaryKey("id", .text)
            t.column("target", .text).notNull()
            t.column("bookId", .text).notNull()
            t.column("chapterNumber", .integer)
            t.column("verseStart", .integer)
            t.column("verseEnd", .integer)
            t.column("summary", .text).notNull()
            t.column("source", .text).notNull()
            t.column("modelId", .text).notNull()
            t.column("createdAt", .datetime).notNull()
        }
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
    migrator.registerMigration("v10_narrationSettings") { db in
        try db.execute(sql: """
            CREATE TABLE narrationSettings (
                id TEXT PRIMARY KEY NOT NULL,
                scope TEXT NOT NULL UNIQUE CHECK (scope = 'narration'),
                enabled BOOLEAN,
                sourceId TEXT, sourceName TEXT, keyRef TEXT,
                ownsKey BOOLEAN NOT NULL,
                preferredVoiceId TEXT, lastAppleVoiceId TEXT,
                rate DOUBLE NOT NULL,
                revision INTEGER NOT NULL,
                retiredKeyRefs TEXT NOT NULL,
                updatedAt DATETIME NOT NULL
            )
            """)
    }

    migrator.registerMigration("v11_narrationStagedKey") { db in
        try db.execute(sql: """
            CREATE TABLE narrationStagedKey (
                id TEXT PRIMARY KEY NOT NULL
            )
            """)
    }

    migrator.registerMigration("v12_narrationPrefetch") { db in
        try db.execute(sql: """
            ALTER TABLE narrationSettings ADD COLUMN prefetchVerseCount INTEGER NOT NULL DEFAULT 2
                CHECK (prefetchVerseCount BETWEEN 0 AND 10)
            """)
    }
}
