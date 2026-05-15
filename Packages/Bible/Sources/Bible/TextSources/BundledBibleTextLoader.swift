import Foundation

/// Loads Bible text from the JSON resources bundled in the `Bible` package.
///
/// Each book is one `WEB-<bookID>.json` file. Books decode on demand and the
/// loader holds no cache — a caller that re-reads a book should retain the
/// returned `BibleBook`.
public struct BundledBibleTextLoader: BibleTextLoader {
    private let bundle: Bundle

    public init() {
        self.bundle = .module
    }

    /// Test seam: read from a fixture bundle instead of the package bundle,
    /// so the missing- and malformed-resource paths can be exercised.
    init(bundle: Bundle) {
        self.bundle = bundle
    }

    public func loadBook(id bookID: String) throws -> BibleBook {
        guard let url = bundle.url(forResource: "WEB-\(bookID)", withExtension: "json") else {
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
