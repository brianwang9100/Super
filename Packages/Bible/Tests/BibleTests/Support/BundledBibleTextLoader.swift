import Foundation
@testable import Bible

/// Test parity oracle for the production SQLite loader. Decodes the source JSON
/// from flat <translation>-<bookID>.json fixtures independently of database generation.
struct BundledBibleTextLoader: BibleTextLoader {
    private let bundle: Bundle

    init() {
        self.bundle = .module
    }

    init(bundle: Bundle) {
        self.bundle = bundle
    }

    func loadChapter(
        bookId: String, chapterNumber: Int, translation: BibleTranslation
    ) throws -> BibleChapter? {
        let book: BibleBook
        do {
            book = try loadBook(id: bookId, translation: translation)
        } catch BibleTextLoaderError.bookNotFound {
            // Match the database loader: missing book returns nil; malformed content throws.
            return nil
        }
        return book.chapter(chapterNumber)
    }

    /// Throws bookNotFound for a missing resource or malformedResource when decoding fails.
    func loadBook(id bookID: String, translation: BibleTranslation) throws -> BibleBook {
        let resourceName = "\(translation.rawValue)-\(bookID)"
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw BibleTextLoaderError.bookNotFound(bookID)
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(BibleBook.self, from: data)
        } catch {
            throw BibleTextLoaderError.malformedResource(bookID)
        }
    }
}
