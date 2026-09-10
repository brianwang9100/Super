public struct BibleBook: Codable, Sendable, Equatable, Identifiable {
    public enum Testament: String, Codable, Sendable {
        case oldTestament = "OT"
        case newTestament = "NT"
    }

    /// Three-letter routing code, e.g. "1PE".
    public let id: String
    public let name: String
    public let testament: Testament
    public let chapters: [BibleChapter]

    public init(id: String, name: String, testament: Testament, chapters: [BibleChapter]) {
        self.id = id
        self.name = name
        self.testament = testament
        self.chapters = chapters
    }

    /// Uses 1-based numbers; returns nil when absent.
    public func chapter(_ number: Int) -> BibleChapter? {
        chapters.first { $0.number == number }
    }
}
