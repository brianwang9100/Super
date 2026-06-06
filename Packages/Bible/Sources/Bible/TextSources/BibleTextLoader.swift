/// Loads structured Bible reading text, one chapter at a time.
///
/// Implementations resolve a chapter from whatever store backs them — in
/// production, the bundled, read-only `bible-text.sqlite`. The per-chapter
/// granularity is deliberate: the reader, `bible.read`, and annotation
/// snapshotting each want exactly one chapter, and loading just that one (rather
/// than decoding a whole book and discarding the rest) is where the perf win is.
public protocol BibleTextLoader: Sendable {
    /// The structured chapter for one translation, or `nil` when the book or
    /// chapter is absent — or the backing store is unavailable (a missing/corrupt
    /// bundle resource), which callers treat the same as "no text" rather than a
    /// crash.
    /// - Throws: `BibleTextLoaderError` when a resource exists but can't be read
    ///   or decoded.
    func loadChapter(bookId: String, chapterNumber: Int, translation: BibleTranslation) throws -> BibleChapter?
}

/// Failures raised by a `BibleTextLoader`.
public enum BibleTextLoaderError: Error, Sendable, Equatable {
    /// No resource exists for the requested book id.
    case bookNotFound(String)
    /// A resource exists but couldn't be read or decoded.
    case malformedResource(String)
}
