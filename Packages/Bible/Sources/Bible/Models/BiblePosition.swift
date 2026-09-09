public struct BiblePosition: Sendable, Equatable, Hashable {
    public let bookId: String
    /// 1-based chapter number.
    public let chapterNumber: Int

    public init(bookId: String, chapterNumber: Int) {
        self.bookId = bookId
        self.chapterNumber = chapterNumber
    }
}
