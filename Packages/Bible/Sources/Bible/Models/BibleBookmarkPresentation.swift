/// Captures chapter and citation when opening the sheet so navigation underneath
/// cannot redirect its writes or title.
public struct BibleBookmarkPresentation: Sendable, Equatable, Identifiable {
    public let bookId: String
    /// 1-based chapter number.
    public let chapterNumber: Int
    public let citation: String

    public var id: String { "\(bookId)/\(chapterNumber)" }

    public init(bookId: String, chapterNumber: Int, citation: String) {
        self.bookId = bookId
        self.chapterNumber = chapterNumber
        self.citation = citation
    }
}
