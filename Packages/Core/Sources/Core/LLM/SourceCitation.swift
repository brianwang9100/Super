import Foundation

public struct SourceCitation: Sendable, Equatable, Codable, Identifiable {
    /// Missing provider IDs are derived from URL plus parse-time ordinal.
    public let id: String
    public let title: String
    public let url: URL
    public let snippet: String?
    /// Nil lets the UI derive a host favicon.
    public let faviconURL: URL?
    public let publishedDate: Date?
    /// Adapter state must round-trip unchanged to keep citations valid; UI must not interpret it.
    public let providerEcho: ProviderEcho?

    public init(
        id: String,
        title: String,
        url: URL,
        snippet: String? = nil,
        faviconURL: URL? = nil,
        publishedDate: Date? = nil,
        providerEcho: ProviderEcho? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.snippet = snippet
        self.faviconURL = faviconURL
        self.publishedDate = publishedDate
        self.providerEcho = providerEcho
    }
}

/// Only the producing adapter interprets these opaque fields.
public struct ProviderEcho: Sendable, Equatable, Codable {
    /// Producing adapter discriminator, e.g. anthropic.web_search.
    public let kind: String
    /// Anthropic `web_search_result.encrypted_content`.
    public let encryptedContent: String?
    /// Anthropic citation `encrypted_index`.
    public let encryptedIndex: String?

    public init(kind: String, encryptedContent: String? = nil, encryptedIndex: String? = nil) {
        self.kind = kind
        self.encryptedContent = encryptedContent
        self.encryptedIndex = encryptedIndex
    }
}
