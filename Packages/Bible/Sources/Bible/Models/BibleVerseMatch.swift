/// Full-text search hit, coalesced per verse number; picker reference parsing uses BibleSearchResult.
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
