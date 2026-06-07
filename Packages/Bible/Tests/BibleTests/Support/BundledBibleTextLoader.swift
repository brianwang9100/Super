import Foundation
@testable import Bible

/// Loads Bible text from the per-book JSON, decoding a whole `BibleBook`.
///
/// This is **not the production loader** — `DatabaseBibleTextLoader` reads chapters
/// from `bible-text.sqlite` at runtime. `BundledBibleTextLoader` is the test-target
/// *parity oracle*: the JSON (now a test fixture under `Fixtures/Text/`) is the
/// authoritative source the sqlite is generated from, so the parity test decodes it
/// here and asserts the DB loader reproduces the identical `BibleChapter`. It also
/// drives the malformed/missing-resource tests.
///
/// Each book is one `<translation>-<bookID>.json` file, e.g. `KJV-1PE.json`,
/// processed flat into the test bundle.
struct BundledBibleTextLoader: BibleTextLoader {
    private let bundle: Bundle

    init() {
        self.bundle = .module
    }

    /// Test seam: read from a caller-supplied bundle instead of the test bundle,
    /// so a test can point at a bundle holding a malformed fixture and exercise the
    /// missing- and malformed-resource paths.
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
            // A missing book mirrors the DB loader's missing-row case: nil, not a
            // throw. A malformed resource still propagates.
            return nil
        }
        return book.chapter(chapterNumber)
    }

    /// Decode a whole book of one translation by its three-letter id, e.g. `"1PE"`.
    /// - Throws: `BibleTextLoaderError` when the book has no resource
    ///   (`bookNotFound`) or its resource can't be decoded (`malformedResource`).
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
