import Foundation

public struct BibleChapter: Codable, Sendable, Equatable, Identifiable {
    public let number: Int
    public let paragraphs: [BibleParagraph]

    public var id: Int { number }

    public init(number: Int, paragraphs: [BibleParagraph]) {
        self.number = number
        self.paragraphs = paragraphs
    }
}

extension BibleChapter {
    /// Coalesces same-number fragments in reading order, joining text with spaces,
    /// flattening line breaks, and excluding headings for lookup and annotation grounding.
    func coalescedVerses() -> [BibleVerse] {
        var order: [Int] = []
        var fragments: [Int: [String]] = [:]
        for paragraph in paragraphs {
            switch paragraph {
            case .heading:
                continue
            case .prose(let verses), .poetry(let verses):
                for verse in verses {
                    if fragments[verse.number] == nil { order.append(verse.number) }
                    fragments[verse.number, default: []].append(verse.text)
                }
            }
        }
        return order.map { number in
            let text = fragments[number, default: []]
                .joined(separator: " ")
                .replacingOccurrences(of: "\n", with: " ")
            return BibleVerse(number: number, text: text)
        }
    }
}
