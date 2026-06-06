import Foundation
import GRDB

/// Full-text content search over the bundled scripture — the retrieval-by-content
/// companion to `BibleTextLoader`'s retrieval-by-reference.
///
/// Injected as a protocol so `SearchBibleTool` depends on the seam (and tests
/// substitute a fake) rather than on GRDB or the bundled database directly.
public protocol BibleTextSearching: Sendable {
    /// Verses whose text matches `query`, ranked by relevance (BM25, best first).
    ///
    /// - Parameters:
    ///   - query: free-text search terms; FTS5 operators in the raw string are
    ///     neutralized, so any input is safe.
    ///   - translation: which translation to search (results never mix
    ///     translations — they'd be near-duplicates).
    ///   - bookId: optional 3-letter book id to scope the search to one book;
    ///     `nil` searches the whole canon.
    ///   - limit: maximum number of hits to return.
    /// - Returns: ranked matches, or `[]` when nothing matches or the query has
    ///   no searchable terms.
    func search(
        query: String, translation: BibleTranslation, bookId: String?, limit: Int
    ) async throws -> [BibleVerseMatch]
}

/// `BibleTextSearching` over the bundled, read-only `bible-text.sqlite` FTS5 index.
public struct BundledBibleTextSearcher: BibleTextSearching {
    private let database: BibleTextDatabase

    /// Production entry point — opens the bundled `bible-text.sqlite`.
    /// - Throws: `BibleTextDatabaseError` when the bundled resource is missing
    ///   or can't be opened.
    public init() throws {
        self.database = try BibleTextDatabase.openBundled()
    }

    /// Test / injection seam.
    init(database: BibleTextDatabase) {
        self.database = database
    }

    public func search(
        query: String, translation: BibleTranslation, bookId: String?, limit: Int
    ) async throws -> [BibleVerseMatch] {
        guard let match = Self.ftsMatch(for: query) else { return [] }
        let queue = database.queue
        return try await queue.read { db in
            var sql = """
            SELECT v.bookId AS bookId, v.chapter AS chapter, v.verse AS verse, v.text AS text
            FROM verse_fts JOIN verse v ON v.id = verse_fts.rowid
            WHERE verse_fts MATCH ? AND v.translation = ?
            """
            var arguments: [DatabaseValueConvertible] = [match, translation.rawValue]
            if let bookId {
                sql += " AND v.bookId = ?"
                arguments.append(bookId)
            }
            sql += " ORDER BY bm25(verse_fts) LIMIT ?"
            arguments.append(limit)
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            return rows.map { row in
                BibleVerseMatch(
                    bookId: row["bookId"], chapter: row["chapter"],
                    verse: row["verse"], text: row["text"]
                )
            }
        }
    }

    /// Turn arbitrary user/LLM text into a safe FTS5 MATCH expression.
    ///
    /// FTS5 MATCH syntax is its own little language — bare `"`, `*`, `(`, `:`,
    /// `-`, `OR`, `NEAR` either error or change the query's meaning. Rather than
    /// pass raw text through, we extract word runs (letters / digits /
    /// apostrophe), wrap each in double quotes (an FTS5 string literal, so its
    /// contents are taken verbatim), and AND them with spaces. The result can
    /// never be a malformed MATCH. Returns `nil` when the input has no
    /// searchable terms.
    static func ftsMatch(for query: String) -> String? {
        let terms = query.split { character in
            !(character.isLetter || character.isNumber || character == "'")
        }
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\($0)\"" }.joined(separator: " ")
    }
}
