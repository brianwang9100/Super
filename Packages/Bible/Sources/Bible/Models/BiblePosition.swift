/// A cursor into the Bible: which book, which chapter the reader is on.
///
/// This is the in-memory navigation value passed between the view model,
/// the book catalog, and the nav bar — distinct from the persisted
/// `BibleReadingPositionRecord`, which also carries a translation and a
/// timestamp.
public struct BiblePosition: Sendable, Equatable, Hashable {
    /// Three-letter book code, e.g. `"1PE"`.
    public let bookId: String
    /// 1-based chapter number.
    public let chapterNumber: Int

    public init(bookId: String, chapterNumber: Int) {
        self.bookId = bookId
        self.chapterNumber = chapterNumber
    }
}
