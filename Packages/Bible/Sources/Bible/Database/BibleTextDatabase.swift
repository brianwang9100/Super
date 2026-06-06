import Foundation
import GRDB

/// Owns the read-only `DatabaseQueue` for the bundled `bible-text.sqlite` —
/// the prebuilt full-text-search index over every verse of all four bundled
/// translations that backs `bible.search`.
///
/// Deliberately separate from `BibleDatabase` (`bible.sqlite`): that database is
/// mutable, migrated, and sync-targeted; this one is an immutable bundle resource
/// generated offline by `Scripts/generate_bible_text_sqlite.py`, opened read-only
/// and never migrated. Keeping the 124k static verse rows out of `bible.sqlite`
/// keeps them out of the sync story entirely.
public struct BibleTextDatabase: Sendable {
    public let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// Open the prebuilt `bible-text.sqlite` shipped in the Bible bundle,
    /// read-only.
    ///
    /// Read-only is both correct (the bundle is immutable) and load-bearing:
    /// it stops SQLite from trying to create `-wal`/`-shm` sidecars next to a
    /// resource inside the app bundle, which would fail.
    /// - Throws: `BibleTextDatabaseError` when the resource is absent or can't
    ///   be opened.
    public static func openBundled() throws -> BibleTextDatabase {
        guard let url = Bundle.module.url(forResource: "bible-text", withExtension: "sqlite") else {
            throw BibleTextDatabaseError.resourceMissing
        }
        var configuration = Configuration()
        configuration.readonly = true
        do {
            let queue = try DatabaseQueue(path: url.path, configuration: configuration)
            return BibleTextDatabase(queue: queue)
        } catch {
            throw BibleTextDatabaseError.openFailed(String(describing: error))
        }
    }

    /// Build an in-memory database with the same schema as the shipped artifact
    /// and the given verses inserted — the test seam, so searcher-logic tests
    /// don't depend on the 50 MB bundled file.
    ///
    /// The schema here mirrors `Scripts/generate_bible_text_sqlite.py` exactly
    /// (including the structured `chapter` table, even though this verse-only seam
    /// leaves it empty); the bundled-consistency test guards the shipped artifact
    /// against the Swift coalescing path, so the two schema expressions can't
    /// silently drift.
    static func makeInMemory(verses: [Row]) throws -> BibleTextDatabase {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: Self.schemaSQL)
            for verse in verses {
                try db.execute(
                    sql: "INSERT INTO verse(translation, bookId, chapter, verse, text) VALUES (?, ?, ?, ?, ?)",
                    arguments: [verse.translation, verse.bookId, verse.chapter, verse.verse, verse.text]
                )
            }
            try db.execute(sql: "INSERT INTO verse_fts(rowid, text) SELECT id, text FROM verse")
        }
        return BibleTextDatabase(queue: queue)
    }

    /// The full schema of `bible-text.sqlite`, mirroring the generator script. Kept
    /// as one constant so every in-memory seam builds the identical shape.
    static let schemaSQL = """
        CREATE TABLE chapter (
          translation TEXT NOT NULL,
          bookId      TEXT NOT NULL,
          number      INTEGER NOT NULL,
          json        TEXT NOT NULL,
          PRIMARY KEY (translation, bookId, number)
        );
        CREATE TABLE verse (
          id          INTEGER PRIMARY KEY,
          translation TEXT NOT NULL,
          bookId      TEXT NOT NULL,
          chapter     INTEGER NOT NULL,
          verse       INTEGER NOT NULL,
          text        TEXT NOT NULL
        );
        CREATE INDEX verse_on_translation_bookId_chapter
          ON verse(translation, bookId, chapter);
        CREATE VIRTUAL TABLE verse_fts USING fts5(
          text,
          content='verse',
          content_rowid='id',
          tokenize='porter unicode61'
        );
        """

    /// Build an in-memory database holding structured `chapter` rows — the seam
    /// for `DatabaseBibleTextLoader` tests, which read the JSON blobs back into
    /// `BibleChapter` without the 50 MB bundled file. The flat `verse`/FTS tables
    /// exist (per `schemaSQL`) but stay empty.
    static func makeInMemory(chapters: [ChapterRow]) throws -> BibleTextDatabase {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: Self.schemaSQL)
            for chapter in chapters {
                try db.execute(
                    sql: "INSERT INTO chapter(translation, bookId, number, json) VALUES (?, ?, ?, ?)",
                    arguments: [chapter.translation, chapter.bookId, chapter.number, chapter.json]
                )
            }
        }
        return BibleTextDatabase(queue: queue)
    }

    /// A verse row for the in-memory test seam.
    struct Row {
        let translation: String
        let bookId: String
        let chapter: Int
        let verse: Int
        let text: String

        init(translation: BibleTranslation, bookId: String, chapter: Int, verse: Int, text: String) {
            self.translation = translation.rawValue
            self.bookId = bookId
            self.chapter = chapter
            self.verse = verse
            self.text = text
        }
    }

    /// A structured `chapter` row for the in-memory test seam. The `json` blob is
    /// produced by encoding a `BibleChapter`, so a round-trip through the loader
    /// returns an equal value.
    struct ChapterRow {
        let translation: String
        let bookId: String
        let number: Int
        let json: String

        init(translation: BibleTranslation, bookId: String, number: Int, chapter: BibleChapter) throws {
            self.translation = translation.rawValue
            self.bookId = bookId
            self.number = number
            self.json = String(decoding: try JSONEncoder().encode(chapter), as: UTF8.self)
        }
    }
}

/// Failures opening the bundled text database.
public enum BibleTextDatabaseError: Error, Sendable, Equatable {
    /// `bible-text.sqlite` was not found in the bundle.
    case resourceMissing
    /// The resource exists but couldn't be opened.
    case openFailed(String)
}
