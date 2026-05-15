/// One chapter of a book — an ordered list of heading, prose, and poetry
/// paragraphs as segmented from the source text.
public struct BibleChapter: Codable, Sendable, Equatable, Identifiable {
    public let number: Int
    public let paragraphs: [BibleParagraph]

    public var id: Int { number }

    public init(number: Int, paragraphs: [BibleParagraph]) {
        self.number = number
        self.paragraphs = paragraphs
    }
}
