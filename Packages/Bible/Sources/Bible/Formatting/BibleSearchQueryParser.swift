import Foundation

/// A resolved deep-link target the book picker's search field produced — a
/// whole chapter or a contiguous verse range. `nil` is the book-only case,
/// which the picker handles by filtering its book list instead.
public enum BibleSearchResult: Sendable, Equatable {
    case chapter(bookId: String, bookName: String, chapterNumber: Int)
    case verseRange(
        bookId: String, bookName: String, chapterNumber: Int, verseStart: Int, verseEnd: Int
    )

    /// The reference as the user would read it, e.g. `"1 Peter 2"`,
    /// `"1 Peter 2:5"`, `"1 Peter 2:5-6"`. Drives the deep-link row's title.
    public var displayLabel: String {
        switch self {
        case let .chapter(_, bookName, chapterNumber):
            return "\(bookName) \(chapterNumber)"
        case let .verseRange(_, bookName, chapterNumber, verseStart, verseEnd):
            if verseStart == verseEnd {
                return "\(bookName) \(chapterNumber):\(verseStart)"
            }
            return "\(bookName) \(chapterNumber):\(verseStart)-\(verseEnd)"
        }
    }

    /// The deep-link row's secondary line describing where a tap lands.
    public var subtitle: String {
        switch self {
        case .chapter:
            return "Go to chapter"
        case let .verseRange(_, _, _, verseStart, verseEnd):
            return verseStart == verseEnd ? "Go to verse" : "Go to verses"
        }
    }
}

/// The picker search field's parsed intent: a substring to filter the book
/// list by, and — when the query named a real chapter or verse range — the
/// deep-link target to surface as a single row instead.
public struct BibleSearchQuery: Sendable, Equatable {
    /// The book-name portion the picker filters its list against (the whole
    /// query when no trailing chapter was typed, just the book part when one
    /// was). Empty shows the full canon.
    public let bookNameQuery: String
    /// Non-nil when the query resolved to a concrete chapter or verse range —
    /// the picker then shows the single deep-link row.
    public let resolved: BibleSearchResult?

    public init(bookNameQuery: String, resolved: BibleSearchResult?) {
        self.bookNameQuery = bookNameQuery
        self.resolved = resolved
    }
}

/// Parses the book picker's search field progressively as the user types —
/// `"1 Peter"` → book-only, `"1 Peter 2"` → a chapter, `"1 Peter 2:5-6"` → a
/// verse range. Deliberately lenient (LLM-emitted citations are parsed by
/// Core's `BibleReferenceLinkifier`/`BibleDeepLink` instead); book names
/// resolve through `BibleBookCatalog.resolve(bookName:)`.
///
/// A caseless namespace: parsing is a pure function with no state.
public enum BibleSearchQueryParser {
    /// Parse `raw` into a book-list filter plus an optional deep-link target.
    ///
    /// A trailing chapter is only recognised in the **space-separated** form
    /// (`"1 Peter 2"`), never glued (`"1Peter2"`), and never when the integer
    /// is the only token — so `"1"` and `"2 John"` keep their leading digit as
    /// part of the book. When a chapter is present but the book is ambiguous
    /// or the chapter is out of range, the result is book-only filtering on
    /// the book part (`"Peter 2"` still lists both Peter books).
    public static func parse(_ raw: String, in catalog: BibleBookCatalog) -> BibleSearchQuery {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return BibleSearchQuery(bookNameQuery: "", resolved: nil) }

        // Split once on the colon: left of it is book + chapter, right is the
        // verse range (which may be empty mid-type, e.g. "1 Peter 2:").
        let colonSplit = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let leftRaw = String(colonSplit[0]).trimmingCharacters(in: .whitespaces)
        let verseRaw = colonSplit.count == 2
            ? String(colonSplit[1]).trimmingCharacters(in: .whitespaces)
            : nil

        guard let (bookPart, chapterNumber) = peelChapter(from: leftRaw) else {
            // No trailing chapter — a plain book-name search. Keep the colon's
            // left side as the filter so a stray colon doesn't break matching.
            return BibleSearchQuery(bookNameQuery: leftRaw, resolved: nil)
        }

        // `resolve` matches on a unique *prefix* of the book name, whereas the
        // picker filters its book list by *substring* (`localizedCaseInsensitiveContains`).
        // The two agree for any reference typed from the start of a book name —
        // the only way to reach the picker. A mid-word fragment plus a chapter
        // (e.g. "lomon 8") substring-matches one book and auto-expands its grid
        // but won't prefix-resolve here, so it yields no deep-link row; that's
        // an acceptable, effectively unreachable corner rather than a bug.
        guard let book = catalog.resolve(bookName: bookPart),
              (1...book.chapterCount).contains(chapterNumber) else {
            // Chapter typed, but the book is ambiguous or the chapter is out of
            // range — fall back to filtering the list by the book part.
            return BibleSearchQuery(bookNameQuery: bookPart, resolved: nil)
        }

        if let verseRaw, let (verseStart, verseEnd) = parseVerseRange(verseRaw) {
            return BibleSearchQuery(
                bookNameQuery: bookPart,
                resolved: .verseRange(
                    bookId: book.id, bookName: book.name, chapterNumber: chapterNumber,
                    verseStart: verseStart, verseEnd: verseEnd
                )
            )
        }

        return BibleSearchQuery(
            bookNameQuery: bookPart,
            resolved: .chapter(bookId: book.id, bookName: book.name, chapterNumber: chapterNumber)
        )
    }

    /// Peel a trailing space-separated integer off `leftRaw` as the chapter,
    /// returning the remaining book part. `nil` when there is no such token
    /// (or it is the only token, which keeps a numeric-prefix book like
    /// `"1 Peter"` intact while the chapter is still untyped).
    private static func peelChapter(from leftRaw: String) -> (bookPart: String, chapter: Int)? {
        let tokens = leftRaw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 2, let last = tokens.last, let chapter = Int(last), chapter >= 1 else {
            return nil
        }
        return (tokens.dropLast().joined(separator: " "), chapter)
    }

    /// Right-of-colon, lenient for in-progress typing: `"5"` → `(5, 5)`,
    /// `"5-6"` → `(5, 6)`, `"5-"` → `(5, 5)` (range end not yet typed). `nil`
    /// for an empty string or an inverted / non-numeric range, in which case
    /// the caller treats the query as a chapter result.
    private static func parseVerseRange(_ raw: String) -> (Int, Int)? {
        guard !raw.isEmpty else { return nil }
        let parts = raw
            .split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        switch parts.count {
        case 1:
            guard let n = Int(parts[0]), n >= 1 else { return nil }
            return (n, n)
        case 2:
            guard let start = Int(parts[0]), start >= 1 else { return nil }
            // A trailing "-" with no end yet (mid-type) collapses to a single
            // verse so the row stays valid as the user keeps typing.
            if parts[1].isEmpty { return (start, start) }
            guard let end = Int(parts[1]), end >= start else { return nil }
            return (start, end)
        default:
            return nil
        }
    }
}
