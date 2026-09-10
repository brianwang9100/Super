@testable import Bible

struct ThrowingBibleTextLoader: BibleTextLoader {
    func loadChapter(
        bookId: String, chapterNumber: Int, translation: BibleTranslation
    ) throws -> BibleChapter? {
        throw BibleTextLoaderError.malformedResource(bookId)
    }
}
