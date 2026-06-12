/// The 66 protestant-canon books in traditional reading order, with the
/// chapter counts needed to step and bound navigation.
///
/// The list mirrors the bundled World English Bible (WEB) text — every
/// book code, name, and chapter count is verified against the decoded
/// `WEB-<id>.json` resources by `BibleBookCatalogTests`, so the catalog
/// can never silently drift from what the reader actually loads.
public struct BibleBookCatalog: Sendable {
    /// Books in canonical order — Genesis first, Revelation last.
    public let books: [BibleBookSummary]

    public init(books: [BibleBookSummary]) {
        self.books = books
    }

    /// The book summary for a three-letter code, or `nil` if unknown.
    public func book(id bookId: String) -> BibleBookSummary? {
        books.first { $0.id == bookId }
    }

    /// Resolve a book-name candidate to its summary, whitespace-insensitively.
    ///
    /// Match order: exact 3-letter id (case-insensitive), then exact display
    /// name with whitespace stripped, then a unique whitespace-stripped prefix
    /// of the display name. Whitespace stripping lets `"1Cor"` resolve to
    /// `"1 Corinthians"` without an abbreviation table; the uniqueness check
    /// rejects ambiguous shorthands (`"J"` matches eight books, so `nil`).
    /// Returns `nil` for an empty candidate or any ambiguous prefix.
    ///
    /// Used by `BibleSearchQueryParser` (the picker's progressive search) —
    /// the single home for how a book name resolves.
    public func resolve(bookName candidate: String) -> BibleBookSummary? {
        let needle = candidate.lowercased().filter { !$0.isWhitespace }
        guard !needle.isEmpty else { return nil }

        for book in books {
            let strippedName = book.name.lowercased().filter { !$0.isWhitespace }
            if needle == book.id.lowercased() || needle == strippedName {
                return book
            }
        }

        let prefixMatches = books.filter { book in
            book.name.lowercased().filter { !$0.isWhitespace }.hasPrefix(needle)
        }
        return prefixMatches.count == 1 ? prefixMatches[0] : nil
    }

    /// The position one chapter away from `position` in `direction`, or
    /// `nil` at the two ends of the canon.
    ///
    /// Stepping crosses book boundaries — past the last chapter of a book
    /// lands on chapter 1 of the next — but Genesis 1 has no previous and
    /// Revelation's final chapter has no next, so callers can disable the
    /// nav controls at those edges.
    ///
    /// `position.chapterNumber` is expected to be within the book's
    /// `1...chapterCount`; callers only ever step from positions the
    /// catalog itself produced. An unknown `bookId` yields `nil`.
    public func step(
        from position: BiblePosition,
        direction: BibleChapterDirection
    ) -> BiblePosition? {
        guard let index = books.firstIndex(where: { $0.id == position.bookId }) else {
            return nil
        }
        let book = books[index]
        switch direction {
        case .next:
            if position.chapterNumber < book.chapterCount {
                return BiblePosition(bookId: book.id, chapterNumber: position.chapterNumber + 1)
            }
            guard index + 1 < books.count else { return nil }
            return BiblePosition(bookId: books[index + 1].id, chapterNumber: 1)
        case .previous:
            if position.chapterNumber > 1 {
                return BiblePosition(bookId: book.id, chapterNumber: position.chapterNumber - 1)
            }
            guard index > 0 else { return nil }
            let previous = books[index - 1]
            return BiblePosition(bookId: previous.id, chapterNumber: previous.chapterCount)
        }
    }
}

extension BibleBookCatalog {
    /// The bundled World English Bible canon.
    public static let standard = BibleBookCatalog(books: [
        // Old Testament
        BibleBookSummary(id: "GEN", name: "Genesis", testament: .oldTestament, chapterCount: 50),
        BibleBookSummary(id: "EXO", name: "Exodus", testament: .oldTestament, chapterCount: 40),
        BibleBookSummary(id: "LEV", name: "Leviticus", testament: .oldTestament, chapterCount: 27),
        BibleBookSummary(id: "NUM", name: "Numbers", testament: .oldTestament, chapterCount: 36),
        BibleBookSummary(id: "DEU", name: "Deuteronomy", testament: .oldTestament, chapterCount: 34),
        BibleBookSummary(id: "JOS", name: "Joshua", testament: .oldTestament, chapterCount: 24),
        BibleBookSummary(id: "JDG", name: "Judges", testament: .oldTestament, chapterCount: 21),
        BibleBookSummary(id: "RUT", name: "Ruth", testament: .oldTestament, chapterCount: 4),
        BibleBookSummary(id: "1SA", name: "1 Samuel", testament: .oldTestament, chapterCount: 31),
        BibleBookSummary(id: "2SA", name: "2 Samuel", testament: .oldTestament, chapterCount: 24),
        BibleBookSummary(id: "1KI", name: "1 Kings", testament: .oldTestament, chapterCount: 22),
        BibleBookSummary(id: "2KI", name: "2 Kings", testament: .oldTestament, chapterCount: 25),
        BibleBookSummary(id: "1CH", name: "1 Chronicles", testament: .oldTestament, chapterCount: 29),
        BibleBookSummary(id: "2CH", name: "2 Chronicles", testament: .oldTestament, chapterCount: 36),
        BibleBookSummary(id: "EZR", name: "Ezra", testament: .oldTestament, chapterCount: 10),
        BibleBookSummary(id: "NEH", name: "Nehemiah", testament: .oldTestament, chapterCount: 13),
        BibleBookSummary(id: "EST", name: "Esther", testament: .oldTestament, chapterCount: 10),
        BibleBookSummary(id: "JOB", name: "Job", testament: .oldTestament, chapterCount: 42),
        BibleBookSummary(id: "PSA", name: "Psalms", testament: .oldTestament, chapterCount: 150),
        BibleBookSummary(id: "PRO", name: "Proverbs", testament: .oldTestament, chapterCount: 31),
        BibleBookSummary(id: "ECC", name: "Ecclesiastes", testament: .oldTestament, chapterCount: 12),
        BibleBookSummary(id: "SNG", name: "Song of Solomon", testament: .oldTestament, chapterCount: 8),
        BibleBookSummary(id: "ISA", name: "Isaiah", testament: .oldTestament, chapterCount: 66),
        BibleBookSummary(id: "JER", name: "Jeremiah", testament: .oldTestament, chapterCount: 52),
        BibleBookSummary(id: "LAM", name: "Lamentations", testament: .oldTestament, chapterCount: 5),
        BibleBookSummary(id: "EZK", name: "Ezekiel", testament: .oldTestament, chapterCount: 48),
        BibleBookSummary(id: "DAN", name: "Daniel", testament: .oldTestament, chapterCount: 12),
        BibleBookSummary(id: "HOS", name: "Hosea", testament: .oldTestament, chapterCount: 14),
        BibleBookSummary(id: "JOL", name: "Joel", testament: .oldTestament, chapterCount: 3),
        BibleBookSummary(id: "AMO", name: "Amos", testament: .oldTestament, chapterCount: 9),
        BibleBookSummary(id: "OBA", name: "Obadiah", testament: .oldTestament, chapterCount: 1),
        BibleBookSummary(id: "JON", name: "Jonah", testament: .oldTestament, chapterCount: 4),
        BibleBookSummary(id: "MIC", name: "Micah", testament: .oldTestament, chapterCount: 7),
        BibleBookSummary(id: "NAM", name: "Nahum", testament: .oldTestament, chapterCount: 3),
        BibleBookSummary(id: "HAB", name: "Habakkuk", testament: .oldTestament, chapterCount: 3),
        BibleBookSummary(id: "ZEP", name: "Zephaniah", testament: .oldTestament, chapterCount: 3),
        BibleBookSummary(id: "HAG", name: "Haggai", testament: .oldTestament, chapterCount: 2),
        BibleBookSummary(id: "ZEC", name: "Zechariah", testament: .oldTestament, chapterCount: 14),
        BibleBookSummary(id: "MAL", name: "Malachi", testament: .oldTestament, chapterCount: 4),
        // New Testament
        BibleBookSummary(id: "MAT", name: "Matthew", testament: .newTestament, chapterCount: 28),
        BibleBookSummary(id: "MRK", name: "Mark", testament: .newTestament, chapterCount: 16),
        BibleBookSummary(id: "LUK", name: "Luke", testament: .newTestament, chapterCount: 24),
        BibleBookSummary(id: "JHN", name: "John", testament: .newTestament, chapterCount: 21),
        BibleBookSummary(id: "ACT", name: "Acts", testament: .newTestament, chapterCount: 28),
        BibleBookSummary(id: "ROM", name: "Romans", testament: .newTestament, chapterCount: 16),
        BibleBookSummary(id: "1CO", name: "1 Corinthians", testament: .newTestament, chapterCount: 16),
        BibleBookSummary(id: "2CO", name: "2 Corinthians", testament: .newTestament, chapterCount: 13),
        BibleBookSummary(id: "GAL", name: "Galatians", testament: .newTestament, chapterCount: 6),
        BibleBookSummary(id: "EPH", name: "Ephesians", testament: .newTestament, chapterCount: 6),
        BibleBookSummary(id: "PHP", name: "Philippians", testament: .newTestament, chapterCount: 4),
        BibleBookSummary(id: "COL", name: "Colossians", testament: .newTestament, chapterCount: 4),
        BibleBookSummary(id: "1TH", name: "1 Thessalonians", testament: .newTestament, chapterCount: 5),
        BibleBookSummary(id: "2TH", name: "2 Thessalonians", testament: .newTestament, chapterCount: 3),
        BibleBookSummary(id: "1TI", name: "1 Timothy", testament: .newTestament, chapterCount: 6),
        BibleBookSummary(id: "2TI", name: "2 Timothy", testament: .newTestament, chapterCount: 4),
        BibleBookSummary(id: "TIT", name: "Titus", testament: .newTestament, chapterCount: 3),
        BibleBookSummary(id: "PHM", name: "Philemon", testament: .newTestament, chapterCount: 1),
        BibleBookSummary(id: "HEB", name: "Hebrews", testament: .newTestament, chapterCount: 13),
        BibleBookSummary(id: "JAS", name: "James", testament: .newTestament, chapterCount: 5),
        BibleBookSummary(id: "1PE", name: "1 Peter", testament: .newTestament, chapterCount: 5),
        BibleBookSummary(id: "2PE", name: "2 Peter", testament: .newTestament, chapterCount: 3),
        BibleBookSummary(id: "1JN", name: "1 John", testament: .newTestament, chapterCount: 5),
        BibleBookSummary(id: "2JN", name: "2 John", testament: .newTestament, chapterCount: 1),
        BibleBookSummary(id: "3JN", name: "3 John", testament: .newTestament, chapterCount: 1),
        BibleBookSummary(id: "JUD", name: "Jude", testament: .newTestament, chapterCount: 1),
        BibleBookSummary(id: "REV", name: "Revelation", testament: .newTestament, chapterCount: 22),
    ])
}
