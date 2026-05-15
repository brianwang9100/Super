import Foundation

/// Loads Bible text from the JSON resources bundled in the `Bible` package.
///
/// Each book is one `<translation>-<bookID>.json` file, e.g. `KJV-1PE.json`.
/// Books decode on demand and the loader holds no cache — a caller that
/// re-reads a book should retain the returned `BibleBook`.
public struct BundledBibleTextLoader: BibleTextLoader {
    private let bundle: Bundle

    public init() {
        self.bundle = .module
    }

    /// Test seam: read from a caller-supplied bundle instead of the package
    /// bundle, so a test can point at a bundle holding a malformed fixture
    /// and exercise the missing- and malformed-resource paths.
    init(bundle: Bundle) {
        self.bundle = bundle
    }

    public func loadBook(id bookID: String, translation: BibleTranslation) throws -> BibleBook {
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
