import Foundation
import GRDB

/// How the words in a multi-word `query` are combined into an FTS5 MATCH.
///
/// `any` is the forgiving default: a topical query like "anxiety hope" should
/// surface verses about *either* theme, ranked best-first by BM25, rather than
/// only the rare verse that happens to contain every word. `all` and `phrase`
/// let a model deliberately narrow when it wants precision or an exact quote.
public enum BibleSearchMatchMode: String, Sendable, CaseIterable {
    /// OR — verses containing *any* of the words, BM25-ranked (default).
    case any
    /// AND — only verses containing *every* word.
    case all
    /// Contiguous phrase — the words adjacent and in order.
    case phrase
}

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
    ///   - mode: how multiple words are combined — `any` (OR, default), `all`
    ///     (AND), or `phrase` (contiguous).
    ///   - limit: maximum number of hits to return.
    /// - Returns: ranked matches, or `[]` when nothing matches or the query has
    ///   no searchable terms.
    func search(
        query: String, translation: BibleTranslation, bookId: String?,
        mode: BibleSearchMatchMode, limit: Int
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
        query: String, translation: BibleTranslation, bookId: String?,
        mode: BibleSearchMatchMode, limit: Int
    ) async throws -> [BibleVerseMatch] {
        guard let match = Self.ftsMatch(for: query, mode: mode) else { return [] }
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
    /// apostrophe) and wrap them in double quotes (FTS5 string literals, taken
    /// verbatim), so the result can never be a malformed MATCH. How the quoted
    /// terms are joined depends on `mode`:
    ///
    /// - `.any`: `OR`-joined — verses matching any term, BM25 floating the ones
    ///   that match more (and rarer) terms to the top.
    /// - `.all`: space-joined — FTS5 implicit AND, every term required.
    /// - `.phrase`: the words wrapped in a single quote pair — an FTS5
    ///   contiguous-phrase match.
    ///
    /// Returns `nil` when the input has no searchable terms.
    static func ftsMatch(for query: String, mode: BibleSearchMatchMode) -> String? {
        let terms = query.split { character in
            !(character.isLetter || character.isNumber || character == "'")
        }
        guard !terms.isEmpty else { return nil }
        switch mode {
        case .any:
            return terms.map { "\"\($0)\"" }.joined(separator: " OR ")
        case .all:
            return terms.map { "\"\($0)\"" }.joined(separator: " ")
        case .phrase:
            return "\"\(terms.joined(separator: " "))\""
        }
    }
}
