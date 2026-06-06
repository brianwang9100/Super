@testable import Bible

/// A `BibleTextLoader` that always fails — drives the reading screen's
/// "chapter unavailable" state in tests without needing a malformed
/// resource fixture.
struct ThrowingBibleTextLoader: BibleTextLoader {
    func loadChapter(
        bookId: String, chapterNumber: Int, translation: BibleTranslation
    ) throws -> BibleChapter? {
        throw BibleTextLoaderError.malformedResource(bookId)
    }
}
