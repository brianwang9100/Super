import Foundation

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

extension BibleChapter {
    /// The chapter's verses in ascending order, with multi-paragraph fragments
    /// of the same verse number coalesced into a single entry.
    ///
    /// A verse whose text straddles a prose/poetry boundary is stored as several
    /// `BibleVerse` fragments sharing one `number` (see `BibleVerse`); this joins
    /// those fragments space-separated, flattens `\n` line breaks to spaces, and
    /// skips headings — so callers downstream of the reader (the `bible.read`
    /// tool, annotation grounding) see exactly one verse per number.
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
