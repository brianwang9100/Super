/// A whole book of the Bible decoded from one bundled translation file.
public struct BibleBook: Codable, Sendable, Equatable, Identifiable {
    /// Old or New Testament — the two canonical groupings the book picker
    /// (a later milestone) sorts into.
    public enum Testament: String, Codable, Sendable {
        case oldTestament = "OT"
        case newTestament = "NT"
    }

    /// Three-letter book code, e.g. `"1PE"` — also the routing identifier.
    public let id: String
    /// Display name, e.g. `"1 Peter"`.
    public let name: String
    public let testament: Testament
    public let chapters: [BibleChapter]

    public init(id: String, name: String, testament: Testament, chapters: [BibleChapter]) {
        self.id = id
        self.name = name
        self.testament = testament
        self.chapters = chapters
    }

    /// The chapter with the given 1-based number, or `nil` if out of range.
    public func chapter(_ number: Int) -> BibleChapter? {
        chapters.first { $0.number == number }
    }
}
