/// One verse returned by content search (`bible.search`): the citation
/// coordinates plus the verse text.
///
/// Distinct from `BibleSearchResult`/`BibleSearchQuery` in `Formatting/`, which
/// model *reference* parsing for the book picker. This is a *content* hit — a
/// verse whose text matched a full-text query — already coalesced to one entry
/// per verse number.
public struct BibleVerseMatch: Sendable, Equatable {
    public let bookId: String
    public let chapter: Int
    public let verse: Int
    public let text: String

    public init(bookId: String, chapter: Int, verse: Int, text: String) {
        self.bookId = bookId
        self.chapter = chapter
        self.verse = verse
        self.text = text
    }
}
