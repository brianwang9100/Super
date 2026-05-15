/// Lightweight metadata for one book — its code, display name, testament,
/// and chapter count — without the chapter text.
///
/// The reader only needs the full `BibleBook` for the chapter on screen;
/// navigation and (later) the book picker work off these summaries, so the
/// app never has to decode all 66 books just to step a chapter.
public struct BibleBookSummary: Sendable, Equatable, Identifiable {
    /// Three-letter book code, e.g. `"1PE"` — also the routing identifier.
    public let id: String
    /// Display name, e.g. `"1 Peter"`.
    public let name: String
    public let testament: BibleBook.Testament
    /// Number of chapters in the book — the upper bound for navigation.
    public let chapterCount: Int

    public init(id: String, name: String, testament: BibleBook.Testament, chapterCount: Int) {
        self.id = id
        self.name = name
        self.testament = testament
        self.chapterCount = chapterCount
    }
}
