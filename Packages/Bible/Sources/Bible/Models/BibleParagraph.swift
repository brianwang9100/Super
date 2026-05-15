/// One block of a chapter: an editorial heading, a prose paragraph, or a
/// poetry stanza. Decoded from a `type`-discriminated JSON object so invalid
/// combinations (a heading carrying verses) can't be represented.
public enum BibleParagraph: Sendable, Equatable {
    case heading(String)
    case prose([BibleVerse])
    case poetry([BibleVerse])
}

extension BibleParagraph: Codable {
    private enum CodingKeys: String, CodingKey { case type, text, verses }
    private enum Kind: String, Codable { case heading, prose, poetry }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .heading:
            self = .heading(try container.decode(String.self, forKey: .text))
        case .prose:
            self = .prose(try container.decode([BibleVerse].self, forKey: .verses))
        case .poetry:
            self = .poetry(try container.decode([BibleVerse].self, forKey: .verses))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .heading(let text):
            try container.encode(Kind.heading, forKey: .type)
            try container.encode(text, forKey: .text)
        case .prose(let verses):
            try container.encode(Kind.prose, forKey: .type)
            try container.encode(verses, forKey: .verses)
        case .poetry(let verses):
            try container.encode(Kind.poetry, forKey: .type)
            try container.encode(verses, forKey: .verses)
        }
    }
}
