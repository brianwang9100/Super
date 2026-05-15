@testable import Bible

/// A `BibleTextLoader` that always fails — drives the reading screen's
/// "chapter unavailable" state in tests without needing a malformed
/// resource fixture.
struct ThrowingBibleTextLoader: BibleTextLoader {
    func loadBook(id bookID: String) throws -> BibleBook {
        throw BibleTextLoaderError.bookNotFound(bookID)
    }
}
