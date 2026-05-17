/// A verse fragment within a paragraph.
///
/// A verse whose text straddles a paragraph or poetry boundary appears as
/// more than one fragment sharing the same `number`; the renderer draws the
/// raised verse number once, on the first fragment only, matching how print
/// Bibles set such verses.
public struct BibleVerse: Codable, Sendable, Equatable {
    public let number: Int
    /// Reading text with USFM markup already stripped. May contain `\n`
    /// line breaks in poetry fragments.
    public let text: String

    public init(number: Int, text: String) {
        self.number = number
        self.text = text
    }
}
