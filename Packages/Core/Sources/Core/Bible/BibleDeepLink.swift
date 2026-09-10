import Foundation

/// Translation is omitted so links preserve the reader's selected translation.
public struct BibleDeepLink: Sendable, Equatable {
    public let bookId: String
    /// One-based chapter; parsing validates it against the book catalog.
    public let chapter: Int
    public let verseStart: Int?
    /// Nil for a single verse or whole chapter; verseStart distinguishes them.
    public let verseEnd: Int?

    public init(bookId: String, chapter: Int, verseStart: Int? = nil, verseEnd: Int? = nil) {
        self.bookId = bookId
        self.chapter = chapter
        self.verseStart = verseStart
        self.verseEnd = verseEnd
    }
}

extension BibleDeepLink {
    // Both targets register this scheme, so dual-install routing is ambiguous.
    // Future target-specific emission must keep accepting historical links.
    public static let urlScheme: String = "super"
    public static let urlHost: String = "bible"
    public static let urlPath: String = "/verse"

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.urlScheme
        components.host = Self.urlHost
        components.path = Self.urlPath
        var query: [URLQueryItem] = [
            URLQueryItem(name: "book", value: bookId),
            URLQueryItem(name: "chapter", value: String(chapter)),
        ]
        if let verseStart {
            let value: String
            if let verseEnd, verseEnd != verseStart {
                value = "\(verseStart)-\(verseEnd)"
            } else {
                value = String(verseStart)
            }
            query.append(URLQueryItem(name: "verses", value: value))
        }
        components.queryItems = query
        // Static scheme/host/path and encoded query items make URL construction valid.
        return components.url!
    }

    /// Nil for an unknown book ID.
    public var displayCitation: String? {
        guard let entry = BibleBookIndex.entry(id: bookId) else { return nil }
        if let verseStart {
            if let verseEnd, verseEnd != verseStart {
                return "\(entry.name) \(chapter):\(verseStart)-\(verseEnd)"
            }
            return "\(entry.name) \(chapter):\(verseStart)"
        }
        return "\(entry.name) \(chapter)"
    }

    public var recordReference: RecordReference {
        let sourceID: String
        if let verseStart {
            if let verseEnd, verseEnd != verseStart {
                sourceID = "\(bookId)/\(chapter)/\(verseStart)-\(verseEnd)"
            } else {
                sourceID = "\(bookId)/\(chapter)/\(verseStart)"
            }
        } else {
            sourceID = "\(bookId)/\(chapter)"
        }
        let label = displayCitation ?? sourceID
        return RecordReference(
            appletID: "bible",
            kind: "verseRange",
            sourceID: sourceID,
            displayLabel: label,
            citation: label,
            snapshot: ""
        )
    }
}

extension BibleDeepLink {
    /// Invalid scheme/host/path, book, chapter, or verse span returns nil for a silent no-op.
    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        guard components.scheme == Self.urlScheme,
              components.host == Self.urlHost,
              components.path == Self.urlPath else { return nil }

        let queryItems = components.queryItems ?? []
        let queryValue: (String) -> String? = { name in
            queryItems.first { $0.name == name }?.value
        }
        guard let bookId = queryValue("book"),
              let chapterRaw = queryValue("chapter"),
              let chapter = Int(chapterRaw) else { return nil }
        guard let entry = BibleBookIndex.entry(id: bookId),
              (1...entry.chapterCount).contains(chapter) else { return nil }

        let verseStart: Int?
        let verseEnd: Int?
        if let versesRaw = queryValue("verses") {
            guard let parsed = Self.parseVerseSpan(versesRaw) else { return nil }
            verseStart = parsed.start
            verseEnd = parsed.end
        } else {
            verseStart = nil
            verseEnd = nil
        }
        self.init(bookId: bookId, chapter: chapter, verseStart: verseStart, verseEnd: verseEnd)
    }

    /// Accepts book/chapter[/verse[-end]] for Bible verseRange records; malformed input returns nil.
    public init?(reference: RecordReference) {
        guard reference.appletID == "bible", reference.kind == "verseRange" else { return nil }
        let parts = reference.sourceID.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let bookId = String(parts[0])
        guard let entry = BibleBookIndex.entry(id: bookId),
              let chapter = Int(parts[1]),
              (1...entry.chapterCount).contains(chapter) else { return nil }
        if parts.count == 2 {
            self.init(bookId: bookId, chapter: chapter)
            return
        }
        guard let span = Self.parseVerseSpan(String(parts[2])) else { return nil }
        self.init(bookId: bookId, chapter: chapter, verseStart: span.start, verseEnd: span.end)
    }

    private static func parseVerseSpan(_ raw: String) -> (start: Int, end: Int?)? {
        if let single = Int(raw) {
            guard single > 0 else { return nil }
            return (single, nil)
        }
        let pieces = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let start = Int(pieces[0]),
              let end = Int(pieces[1]),
              start > 0, end > 0, end >= start else { return nil }
        if start == end { return (start, nil) }
        return (start, end)
    }
}
