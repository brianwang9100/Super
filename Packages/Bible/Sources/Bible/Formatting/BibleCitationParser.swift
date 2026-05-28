import Foundation

/// Parses a scripture citation string into a structured position + verse
/// range. The format-direction sibling of `BibleCitationFormatter`.
///
/// Accepts the citation forms an LLM (Large Language Model) is likely to
/// produce when filling a `.reference`-kind annotation body:
///
/// - `"John 3:16"` — single verse
/// - `"John 3:16-17"` — range
/// - `"1 Corinthians 13:4-7"` — multi-word book + range
/// - `"1Cor 13:4"`, `"1 Cor 13:4"`, `"1 cor 13:4"` — case-insensitive, with
///   or without the space between the prefix digit and the book name
/// - `"Heb 4:15"` — 3-letter abbreviation matched against
///   `BibleBookCatalog.standard` book ids
///
/// Returns `nil` for any input the parser can't resolve to a real book or
/// a real verse range — the caller renders the original body as plain text
/// when this happens, so a malformed citation still surfaces its content.
///
/// A caseless namespace: parsing is a pure function with no state.
public enum BibleCitationParser {
    /// One parsed citation. `verseEnd == verseStart` for a single verse.
    public struct ParsedCitation: Sendable, Equatable {
        public let position: BiblePosition
        public let verseStart: Int
        public let verseEnd: Int

        public init(position: BiblePosition, verseStart: Int, verseEnd: Int) {
            self.position = position
            self.verseStart = verseStart
            self.verseEnd = verseEnd
        }
    }

    public static func parse(
        _ input: String,
        in catalog: BibleBookCatalog
    ) -> ParsedCitation? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Citation form requires a colon between chapter and verse.
        let colonSplit = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard colonSplit.count == 2 else { return nil }
        let leftRaw = String(colonSplit[0]).trimmingCharacters(in: .whitespaces)
        let rightRaw = String(colonSplit[1]).trimmingCharacters(in: .whitespaces)
        guard !leftRaw.isEmpty, !rightRaw.isEmpty else { return nil }

        guard let (verseStart, verseEnd) = parseVerseRange(rightRaw) else { return nil }
        guard let (bookName, chapterNumber) = splitBookAndChapter(leftRaw) else { return nil }
        guard let position = matchBook(bookName, chapterNumber: chapterNumber, in: catalog) else { return nil }

        return ParsedCitation(position: position, verseStart: verseStart, verseEnd: verseEnd)
    }

    /// Right-of-colon: `"16"` → `(16, 16)`; `"16-17"` → `(16, 17)`. Rejects
    /// anything else.
    private static func parseVerseRange(_ raw: String) -> (Int, Int)? {
        let parts = raw
            .split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        switch parts.count {
        case 1:
            guard let n = Int(parts[0]), n >= 1 else { return nil }
            return (n, n)
        case 2:
            guard let s = Int(parts[0]), s >= 1,
                  let e = Int(parts[1]), e >= s else { return nil }
            return (s, e)
        default:
            return nil
        }
    }

    /// Left-of-colon: separate `"1 Corinthians 13"` into `("1 Corinthians",
    /// 13)`. Also accepts glued forms like `"John3"` (no whitespace between
    /// book and chapter) by splitting at the first digit.
    private static func splitBookAndChapter(_ raw: String) -> (String, Int)? {
        let tokens = raw.split(separator: " ", omittingEmptySubsequences: true).map { String($0) }
        if tokens.count >= 2, let chapter = Int(tokens.last!), chapter >= 1 {
            return (tokens.dropLast().joined(separator: " "), chapter)
        }
        // Glued form: split at the first digit so `"John3"` resolves.
        // First-position digit means no book name at all (e.g. `"3:16"`),
        // which we reject — every citation needs a book.
        guard let firstDigit = raw.firstIndex(where: { $0.isNumber }),
              firstDigit > raw.startIndex
        else { return nil }
        let bookPart = String(raw[..<firstDigit]).trimmingCharacters(in: .whitespaces)
        let chapterPart = String(raw[firstDigit...])
        guard let chapter = Int(chapterPart), chapter >= 1, !bookPart.isEmpty else { return nil }
        return (bookPart, chapter)
    }

    /// Resolve a book name candidate against the catalog.
    ///
    /// Match order: exact match against the 3-letter id (case-insensitive),
    /// exact match against the display name with whitespace stripped, then
    /// unique whitespace-stripped prefix match against the display name.
    /// Whitespace stripping lets `"1Cor"` resolve to `"1 Corinthians"`
    /// without a separate abbreviation table; uniqueness on the prefix
    /// rejects ambiguous shorthands (`"J"` matches John, Jonah, Joshua,
    /// James, Jeremiah, Judges, Jude, Joel — eight books, so nil).
    private static func matchBook(
        _ name: String,
        chapterNumber: Int,
        in catalog: BibleBookCatalog
    ) -> BiblePosition? {
        let candidate = name.lowercased().filter { !$0.isWhitespace }
        guard !candidate.isEmpty else { return nil }

        for book in catalog.books {
            let bookId = book.id.lowercased()
            let bookName = book.name.lowercased().filter { !$0.isWhitespace }
            if candidate == bookId || candidate == bookName {
                return chapterPosition(for: book, chapterNumber: chapterNumber)
            }
        }

        let prefixMatches = catalog.books.filter { book in
            book.name.lowercased().filter { !$0.isWhitespace }.hasPrefix(candidate)
        }
        if prefixMatches.count == 1 {
            return chapterPosition(for: prefixMatches[0], chapterNumber: chapterNumber)
        }
        return nil
    }

    private static func chapterPosition(
        for book: BibleBookSummary,
        chapterNumber: Int
    ) -> BiblePosition? {
        guard chapterNumber <= book.chapterCount else { return nil }
        return BiblePosition(bookId: book.id, chapterNumber: chapterNumber)
    }
}
