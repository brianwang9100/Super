/// The chapter whose bookmark sheet is presented — drives the
/// `.sheet(item:)` in `BibleScreen`.
///
/// Captures the chapter *and* its formatted citation at presentation time,
/// so the sheet keeps writing (and titling) the chapter it was opened for
/// even if the reader steps underneath it (e.g. a deep link landing while
/// the sheet is up).
public struct BibleBookmarkPresentation: Sendable, Equatable, Identifiable {
    /// Three-letter book code, e.g. `"JHN"`.
    public let bookId: String
    /// 1-based chapter number.
    public let chapterNumber: Int
    /// Human-readable chapter citation for the nav bar title, e.g. `"John 3"`.
    public let citation: String

    public var id: String { "\(bookId)/\(chapterNumber)" }

    public init(bookId: String, chapterNumber: Int, citation: String) {
        self.bookId = bookId
        self.chapterNumber = chapterNumber
        self.citation = citation
    }
}
