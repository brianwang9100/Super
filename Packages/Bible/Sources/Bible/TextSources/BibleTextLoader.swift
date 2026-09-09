public protocol BibleTextLoader: Sendable {
    /// Nil means absent text or unavailable storage. Existing unreadable/undecodable
    /// resources throw BibleTextLoaderError.
    func loadChapter(bookId: String, chapterNumber: Int, translation: BibleTranslation) throws -> BibleChapter?
}

public enum BibleTextLoaderError: Error, Sendable, Equatable {
    case bookNotFound(String)
    case malformedResource(String)
}
