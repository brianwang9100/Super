import Core
import Foundation

/// Non-text payloads attached to a `MessageRecord`, serialized to the
/// `attachmentsJSON` column. Carries cross-applet record references (Bible verse
/// pills) and web-search citations; the shape is versioned so future attachment
/// kinds add fields here rather than new columns.
public struct MessageAttachments: Codable, Sendable, Equatable {
    public var references: [RecordReference]
    /// Web sources cited in a grounded assistant answer (native or standalone
    /// search). Rendered as the collapsible "N sources" pill.
    public var sources: [SourceCitation]
    /// Provider-mandated search-attribution HTML (Gemini "Google Search
    /// Suggestions") that must be rendered unmodified; `nil` for all others.
    public var searchSuggestionsHTML: String?
    /// The query the assistant searched for, captured from the provider's
    /// `.searchStarted` event (or the mock fulfiller). Surfaced in the
    /// expandable "Web search" cell. `nil` when the turn ran no search.
    public var searchQuery: String?
    /// Human label for the search engine used — `"Native search"` for a
    /// native backend, `"Debug (mock)"` for the mock backend, else the
    /// provider's own display name (the DEBUG canned provider fakes citations
    /// with no real backend). Derived at turn time; `nil` when the turn ran no
    /// search.
    public var searchSystem: String?

    public init(
        references: [RecordReference] = [],
        sources: [SourceCitation] = [],
        searchSuggestionsHTML: String? = nil,
        searchQuery: String? = nil,
        searchSystem: String? = nil
    ) {
        self.references = references
        self.sources = sources
        self.searchSuggestionsHTML = searchSuggestionsHTML
        self.searchQuery = searchQuery
        self.searchSystem = searchSystem
    }

    public var isEmpty: Bool {
        references.isEmpty && sources.isEmpty && searchSuggestionsHTML == nil
            && searchQuery == nil && searchSystem == nil
    }

    // Custom decoding so rows written before these keys existed (keys absent)
    // still decode cleanly.
    private enum CodingKeys: String, CodingKey {
        case references, sources, searchSuggestionsHTML, searchQuery, searchSystem
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `references` (Bible verse pills) is the load-bearing field already in
        // production; decode it first so nothing below can affect it.
        self.references = try container.decodeIfPresent([RecordReference].self, forKey: .references) ?? []
        // Contain the blast radius of a malformed `sources` element: a single
        // bad citation (e.g. a future adapter emitting an invalid URL) must not
        // throw and take the whole sidecar — and its `references` — down with it
        // via the `try?` in `MessageRecord.attachments`. Degrade to [] instead.
        self.sources = (try? container.decodeIfPresent([SourceCitation].self, forKey: .sources)) ?? []
        self.searchSuggestionsHTML = try? container.decodeIfPresent(String.self, forKey: .searchSuggestionsHTML)
        self.searchQuery = try? container.decodeIfPresent(String.self, forKey: .searchQuery)
        self.searchSystem = try? container.decodeIfPresent(String.self, forKey: .searchSystem)
    }
}
