import Core
import Foundation

public struct MessageAttachments: Codable, Sendable, Equatable {
    public var references: [RecordReference]
    public var sources: [SourceCitation]
    /// Provider-required attribution HTML; render unmodified.
    public var searchSuggestionsHTML: String?
    public var searchQuery: String?
    /// Human-readable search engine label captured at turn time; nil when no search ran.
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

    // Missing keys must decode for rows written before attachments gained these fields.
    private enum CodingKeys: String, CodingKey {
        case references, sources, searchSuggestionsHTML, searchQuery, searchSystem
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.references = try container.decodeIfPresent([RecordReference].self, forKey: .references) ?? []
        // Bad citations must not discard the whole sidecar and its verse references.
        self.sources = (try? container.decodeIfPresent([SourceCitation].self, forKey: .sources)) ?? []
        self.searchSuggestionsHTML = try? container.decodeIfPresent(String.self, forKey: .searchSuggestionsHTML)
        self.searchQuery = try? container.decodeIfPresent(String.self, forKey: .searchQuery)
        self.searchSystem = try? container.decodeIfPresent(String.self, forKey: .searchSystem)
    }
}
