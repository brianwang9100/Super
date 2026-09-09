public struct BibleBookSummary: Sendable, Equatable, Identifiable {
    /// Three-letter routing code, e.g. "1PE".
    public let id: String
    public let name: String
    public let testament: BibleBook.Testament
    public let chapterCount: Int

    public init(id: String, name: String, testament: BibleBook.Testament, chapterCount: Int) {
        self.id = id
        self.name = name
        self.testament = testament
        self.chapterCount = chapterCount
    }
}
