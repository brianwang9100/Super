import Foundation

/// Structured coordinates for a Bible verse-range deep link, mapping
/// freely between three representations:
///
/// 1. **URL** — `super://bible/verse?book=GEN&chapter=1&verses=1-10`,
///    embedded by the Chat verse linkifier into rendered markdown and
///    delivered via SwiftUI's `OpenURLAction` (in-app taps) or the app
///    scene's `.onOpenURL` (external deep links).
/// 2. **`RecordReference`** — the existing generic cross-applet payload
///    travelled by `SuperEvent.openRecord(reference:)`. Receiver applets
///    decode coordinates back from this.
/// 3. **Native fields** — `bookId` / `chapter` / `verseStart` / `verseEnd`,
///    consumed by `BibleScreenViewModel.openReference`.
///
/// Translation is intentionally absent: the link carries no translation
/// hint, so the reader opens at whichever translation the user is
/// currently on. Forcing the LLM's chosen translation onto the user
/// would be the wrong call for a personal reading app.
public struct BibleDeepLink: Sendable, Equatable {
    /// USFM-style three-letter code matching `BibleBookIndex.entry(id:)`.
    public let bookId: String
    /// 1-based chapter number, must lie in `1...book.chapterCount`.
    public let chapter: Int
    /// First selected verse, `nil` for a chapter-only reference like
    /// `Psalm 23`.
    public let verseStart: Int?
    /// Last selected verse, `nil` when the reference is a single verse
    /// (`John 3:16`, where `verseStart == 16` and `verseEnd == nil`) or
    /// a whole-chapter reference (where both are `nil`).
    public let verseEnd: Int?

    public init(bookId: String, chapter: Int, verseStart: Int? = nil, verseEnd: Int? = nil) {
        self.bookId = bookId
        self.chapter = chapter
        self.verseStart = verseStart
        self.verseEnd = verseEnd
    }
}

extension BibleDeepLink {
    /// URL scheme + host used for every Bible deep link. The shell
    /// registers `super` as a custom URL scheme in `Info.plist`; the
    /// `bible` host disambiguates from future per-applet hosts.
    ///
    /// **Dual-install collision (v1, known):** both `SuperOS` and
    /// `SuperBible` register the same `super` scheme. On a device with
    /// both apps installed, iOS routes a `super://...` URL to whichever
    /// app was *installed most recently* — no system picker, no in-app
    /// signal that the other was a candidate. Acceptable for v1
    /// because both apps embed Bible and handle the `super://bible/...`
    /// host the same way. Per-target namespacing (`superos://` /
    /// `superbible://`) is the follow-up; the migration shape is:
    /// (1) add a target-injected emission scheme set by each app's
    /// bootstrap so the Chat linkifier emits its target's scheme;
    /// (2) keep `parse(_:)` accepting the historical schemes so links
    /// shared between users still resolve.
    public static let urlScheme: String = "super"
    public static let urlHost: String = "bible"
    public static let urlPath: String = "/verse"

    /// Encode the coordinates as a `super://bible/verse?...` URL.
    /// Always succeeds for any valid `BibleDeepLink` — the URL is built
    /// from `URLComponents`, which never fails for our static scheme/host.
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
        // `URLComponents` with a static scheme/host/path always produces
        // a valid URL; the force-unwrap is annotated to reflect that.
        return components.url!
    }

    /// The canonical human label, matching the form the LLM emitted that
    /// produced this link — e.g. `"Genesis 1:1-10"`, `"John 3:16"`,
    /// `"Psalm 23"`. `nil` if the bookId isn't in `BibleBookIndex` (which
    /// should never happen for a `BibleDeepLink` constructed by the
    /// linkifier, but a raw external deep link could in principle).
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

    /// Wrap the coordinates as the generic cross-applet payload Bible's
    /// event-bus subscriber consumes. Mirror of `init(reference:)`.
    /// `appletID` is `"bible"` and `kind` is `"verseRange"` — the same
    /// strings used by the existing "add Bible reference to chat" flow,
    /// so receivers can discriminate without growing a parallel kind.
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
    /// Parse a `super://bible/verse?book=...&chapter=...[&verses=...]` URL
    /// back into coordinates. Returns `nil` on any structural mismatch:
    /// wrong scheme/host/path, missing required params, non-integer
    /// numerics, unknown book ID, out-of-range chapter, malformed verse
    /// range (`verses=foo`, `verses=10-5` inverted, `verses=0`).
    ///
    /// The strictness is deliberate: invalid deep links should silently
    /// no-op (the receiver gets nothing to publish) rather than open a
    /// half-broken view. The matching test suite covers the rejection
    /// cases explicitly so future relaxations are conscious choices.
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

    /// Parse coordinates back from the generic cross-applet `RecordReference`
    /// payload. Mirrors `recordReference`'s sourceID grammar:
    /// `<bookId>/<chapter>[/<verseStart>[-<verseEnd>]]`. Returns `nil` for
    /// the wrong `appletID`/`kind`, malformed sourceID, or an unknown
    /// book.
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

    /// Decode either `"<n>"` or `"<start>-<end>"` into the two slots,
    /// rejecting zero, negative, inverted, or non-integer pieces. Shared
    /// between URL and RecordReference parsing so the two paths can't
    /// drift on what they accept.
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
