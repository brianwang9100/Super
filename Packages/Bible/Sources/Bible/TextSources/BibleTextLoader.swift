/// Loads whole books of Bible reading text.
///
/// Implementations resolve a book from whatever store backs them — in MVP,
/// JSON resources bundled in the app.
public protocol BibleTextLoader: Sendable {
    /// Load a whole book of one translation by its three-letter id, e.g.
    /// `"1PE"`.
    /// - Throws: `BibleTextLoaderError` when the book has no resource or its
    ///   resource can't be decoded.
    func loadBook(id bookID: String, translation: BibleTranslation) throws -> BibleBook
}

/// Failures raised by a `BibleTextLoader`.
public enum BibleTextLoaderError: Error, Sendable, Equatable {
    /// No resource exists for the requested book id.
    case bookNotFound(String)
    /// A resource exists but couldn't be read or decoded.
    case malformedResource(String)
}
