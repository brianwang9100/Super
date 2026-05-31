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

    public init(
        references: [RecordReference] = [],
        sources: [SourceCitation] = [],
        searchSuggestionsHTML: String? = nil
    ) {
        self.references = references
        self.sources = sources
        self.searchSuggestionsHTML = searchSuggestionsHTML
    }

    public var isEmpty: Bool {
        references.isEmpty && sources.isEmpty && searchSuggestionsHTML == nil
    }

    // Custom decoding so rows written before `sources` / `searchSuggestionsHTML`
    // existed (keys absent) still decode cleanly.
    private enum CodingKeys: String, CodingKey {
        case references, sources, searchSuggestionsHTML
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.references = try container.decodeIfPresent([RecordReference].self, forKey: .references) ?? []
        self.sources = try container.decodeIfPresent([SourceCitation].self, forKey: .sources) ?? []
        self.searchSuggestionsHTML = try container.decodeIfPresent(String.self, forKey: .searchSuggestionsHTML)
    }
}
