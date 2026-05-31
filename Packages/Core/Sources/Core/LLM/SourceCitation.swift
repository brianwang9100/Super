import Foundation

/// A single web source cited in a grounded assistant response, normalized across
/// native providers (Anthropic, Gemini, OpenAI) and the standalone search engine
/// (Tavily, Brave) so the transcript renders citations identically regardless of
/// where they came from. Persisted in a message's attachments sidecar.
public struct SourceCitation: Sendable, Equatable, Codable, Identifiable {
    /// Stable identity. Providers that don't supply one get a value derived from
    /// `url` plus the citation's ordinal at parse time.
    public let id: String
    public let title: String
    public let url: URL
    /// The quoted/grounding excerpt when the provider supplies one (Anthropic
    /// `cited_text`, Gemini grounding-segment text); `nil` otherwise.
    public let snippet: String?
    /// Favicon URL when known (standalone providers may fill this); native
    /// providers leave it `nil` and the UI derives a host favicon.
    public let faviconURL: URL?
    /// Publication date when the provider exposes one (Anthropic `page_age`).
    public let publishedDate: Date?
    /// Opaque provider state that MUST be echoed back on later turns for the
    /// citation to remain valid. Anthropic-only today; `nil` for Gemini/OpenAI
    /// and standalone. Stored but never inspected by the UI.
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

/// Opaque, provider-specific data that must round-trip verbatim across turns for
/// a citation to stay valid. Only the adapter that produced it reads it back; the
/// rest of the app treats it as an opaque blob.
public struct ProviderEcho: Sendable, Equatable, Codable {
    /// Discriminator naming the producing adapter, e.g. `"anthropic.web_search"`.
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
