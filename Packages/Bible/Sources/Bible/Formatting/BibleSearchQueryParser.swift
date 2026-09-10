import Foundation

public enum BibleSearchResult: Sendable, Equatable {
    case chapter(bookId: String, bookName: String, chapterNumber: Int)
    case verseRange(
        bookId: String, bookName: String, chapterNumber: Int, verseStart: Int, verseEnd: Int
    )

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

    public var subtitle: String {
        switch self {
        case .chapter:
            return "Go to chapter"
        case let .verseRange(_, _, _, verseStart, verseEnd):
            return verseStart == verseEnd ? "Go to verse" : "Go to verses"
        }
    }
}

public struct BibleSearchQuery: Sendable, Equatable {
    /// Empty shows the full canon; a parsed chapter suffix is excluded from this filter.
    public let bookNameQuery: String
    public let resolved: BibleSearchResult?

    public init(bookNameQuery: String, resolved: BibleSearchResult?) {
        self.bookNameQuery = bookNameQuery
        self.resolved = resolved
    }
}

/// Lenient parser for progressive picker input. LLM citations use Core's linkifier instead.
public enum BibleSearchQueryParser {
    /// Requires a space-separated chapter ("1 Peter 2", not "1Peter2"). A lone number
    /// remains a book filter. Ambiguous books or invalid chapters fall back to book filtering.
    public static func parse(_ raw: String, in catalog: BibleBookCatalog) -> BibleSearchQuery {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return BibleSearchQuery(bookNameQuery: "", resolved: nil) }

        // Preserve an empty verse suffix while the user types, e.g. "1 Peter 2:".
        let colonSplit = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let leftRaw = String(colonSplit[0]).trimmingCharacters(in: .whitespaces)
        let verseRaw = colonSplit.count == 2
            ? String(colonSplit[1]).trimmingCharacters(in: .whitespaces)
            : nil

        guard let (bookPart, chapterNumber) = peelChapter(from: leftRaw) else {
            return BibleSearchQuery(bookNameQuery: leftRaw, resolved: nil)
        }

        // Resolution uses a unique prefix; the picker's substring filter can match fragments
        // that do not resolve here, such as "lomon 8".
        guard let book = catalog.resolve(bookName: bookPart),
              (1...book.chapterCount).contains(chapterNumber) else {
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

    private static func peelChapter(from leftRaw: String) -> (bookPart: String, chapter: Int)? {
        let tokens = leftRaw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 2, let last = tokens.last, let chapter = Int(last), chapter >= 1 else {
            return nil
        }
        return (tokens.dropLast().joined(separator: " "), chapter)
    }

    /// Accepts unfinished "5-" as verse 5. Empty, inverted, or nonnumeric ranges return
    /// nil so the caller can show the chapter result.
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
            if parts[1].isEmpty { return (start, start) }
            guard let end = Int(parts[1]), end >= start else { return nil }
            return (start, end)
        default:
            return nil
        }
    }
}
