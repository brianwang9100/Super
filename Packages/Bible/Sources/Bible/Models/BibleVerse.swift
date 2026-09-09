/// Paragraph boundaries may split one verse into fragments sharing the same number.
/// Only the first fragment displays the raised number.
public struct BibleVerse: Codable, Sendable, Equatable {
    public let number: Int
    /// USFM markup is stripped; poetry may retain newline breaks.
    public let text: String

    public init(number: Int, text: String) {
        self.number = number
        self.text = text
    }
}
