import Foundation
import GRDB

public enum BibleSearchMatchMode: String, Sendable, CaseIterable {
    /// OR; default for topical queries, ranked by BM25.
    case any
    /// AND; every term must match.
    case all
    /// Adjacent words in order.
    case phrase
}

public protocol BibleTextSearching: Sendable {
    /// BM25-ranked within one translation; nil bookId searches the canon. Raw FTS5
    /// operators are neutralized. Empty/unsearchable queries return no hits.
    func search(
        query: String, translation: BibleTranslation, bookId: String?,
        mode: BibleSearchMatchMode, limit: Int
    ) async throws -> [BibleVerseMatch]
}

public struct BundledBibleTextSearcher: BibleTextSearching {
    private let database: BibleTextDatabase

    /// Throws BibleTextDatabaseError if bundled text is missing or unreadable.
    public init() throws {
        self.database = try BibleTextDatabase.openBundled()
    }

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

    // Extract and quote word runs so FTS5 operators cannot alter or invalidate MATCH.
    // Join by the selected mode; return nil without searchable terms.
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
