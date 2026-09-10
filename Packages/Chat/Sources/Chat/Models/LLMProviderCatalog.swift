import Core
import Foundation

public struct LLMCatalogModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let maxContextTokens: Int
    public let supportsThinking: Bool

    public init(
        id: String,
        displayName: String? = nil,
        maxContextTokens: Int,
        supportsThinking: Bool
    ) {
        self.id = id
        self.displayName = displayName ?? id
        self.maxContextTokens = maxContextTokens
        self.supportsThinking = supportsThinking
    }
}

public struct LLMProviderCatalogEntry: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let kind: LLMProviderKind
    public let defaultBaseURL: URL?
    public let nativeSearchAdapter: LLMProviderKind?
    public let nativeSearchBaseURL: URL?
    public let models: [LLMCatalogModel]

    public var supportsNativeSearch: Bool { nativeSearchAdapter != nil }

    public init(
        id: String,
        displayName: String,
        kind: LLMProviderKind,
        defaultBaseURL: URL?,
        models: [LLMCatalogModel],
        nativeSearchAdapter: LLMProviderKind? = nil,
        nativeSearchBaseURL: URL? = nil
    ) {
        self.id = id
        self.displayName = displayName
        precondition(
            (nativeSearchAdapter == nil) == (nativeSearchBaseURL == nil),
            "nativeSearchAdapter and nativeSearchBaseURL must both be set or both be nil"
        )
        self.kind = kind
        self.defaultBaseURL = defaultBaseURL
        self.models = models
        self.nativeSearchAdapter = nativeSearchAdapter
        self.nativeSearchBaseURL = nativeSearchBaseURL
    }
}

public enum LLMProviderCatalog {
    public static let customProviderID = "custom"

    public static let appleProviderID = "apple"

    public static let anthropicNativeBaseURL = URL(string: "https://api.anthropic.com/v1")!
    public static let geminiNativeBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
    /// Shares OpenAI's compatibility URL, so edit classification must check `kind` first.
    public static let openAIResponsesBaseURL = URL(string: "https://api.openai.com/v1")!

    public static let all: [LLMProviderCatalogEntry] = [
        LLMProviderCatalogEntry(
            id: appleProviderID,
            displayName: "Apple",
            kind: .appleFoundation,
            defaultBaseURL: nil,
            models: [
                // Static fallback only; Apple rows use the live deviceContextTokens value.
                LLMCatalogModel(
                    id: "system-default",
                    displayName: "Apple Intelligence",
                    maxContextTokens: 4_096,
                    supportsThinking: false
                ),
            ]
        ),
        LLMProviderCatalogEntry(
            id: "openai",
            displayName: "OpenAI",
            kind: .openAICompatible,
            defaultBaseURL: URL(string: "https://api.openai.com/v1"),
            models: [
                LLMCatalogModel(id: "gpt-5.5", maxContextTokens: 1_000_000, supportsThinking: true),
                LLMCatalogModel(id: "gpt-5.5-pro", maxContextTokens: 1_000_000, supportsThinking: true),
                LLMCatalogModel(id: "gpt-5.4-mini", maxContextTokens: 400_000, supportsThinking: false),
                LLMCatalogModel(id: "gpt-5.4-nano", maxContextTokens: 400_000, supportsThinking: false),
            ],
            nativeSearchAdapter: .openAIResponses,
            nativeSearchBaseURL: openAIResponsesBaseURL
        ),
        LLMProviderCatalogEntry(
            id: "anthropic",
            displayName: "Anthropic",
            // Native Messages is required for explicit cache breakpoints.
            kind: .anthropicNative,
            defaultBaseURL: anthropicNativeBaseURL,
            models: [
                LLMCatalogModel(id: "claude-opus-4-7", maxContextTokens: 1_000_000, supportsThinking: true),
                LLMCatalogModel(id: "claude-sonnet-4-6", maxContextTokens: 200_000, supportsThinking: true),
                LLMCatalogModel(id: "claude-haiku-4-5-20251001", maxContextTokens: 200_000, supportsThinking: false),
            ],
            nativeSearchAdapter: .anthropicNative,
            nativeSearchBaseURL: anthropicNativeBaseURL
        ),
        LLMProviderCatalogEntry(
            id: "google",
            displayName: "Google",
            // Native Gemini preserves required tool-call thought signatures.
            kind: .geminiNative,
            defaultBaseURL: geminiNativeBaseURL,
            models: [
                LLMCatalogModel(id: "gemini-3-pro", maxContextTokens: 1_000_000, supportsThinking: true),
                LLMCatalogModel(id: "gemini-3.5-flash", maxContextTokens: 1_000_000, supportsThinking: true),
                LLMCatalogModel(id: "gemini-3-flash", maxContextTokens: 1_000_000, supportsThinking: true),
            ],
            nativeSearchAdapter: .geminiNative,
            nativeSearchBaseURL: geminiNativeBaseURL
        ),
        LLMProviderCatalogEntry(
            id: "xai",
            displayName: "xAI",
            kind: .openAICompatible,
            defaultBaseURL: URL(string: "https://api.x.ai/v1"),
            models: [
                LLMCatalogModel(id: "grok-4.3", maxContextTokens: 1_000_000, supportsThinking: true),
            ]
        ),
        LLMProviderCatalogEntry(
            id: customProviderID,
            displayName: "Custom",
            kind: .openAICompatible,
            defaultBaseURL: nil,
            models: []
        ),
    ]

    public static func entry(forID providerID: String) -> LLMProviderCatalogEntry? {
        all.first(where: { $0.id == providerID })
    }

    public static func model(forModelId modelId: String) -> (provider: LLMProviderCatalogEntry, model: LLMCatalogModel)? {
        for entry in all {
            if let match = entry.models.first(where: { $0.id == modelId }) {
                return (entry, match)
            }
        }
        return nil
    }

    public static let defaultFetchedMaxContextTokens = 200_000

    /// Preserves catalog order and metadata for known IDs, then appends unknown
    /// fetched IDs alphabetically with conservative defaults.
    public static func reconcile(providerID: String, fetchedModelIDs: [String]) -> [LLMCatalogModel] {
        var seen = Set<String>()
        let uniqueFetched = fetchedModelIDs.filter { seen.insert($0).inserted }
        let fetchedSet = Set(uniqueFetched)

        let catalogModels = entry(forID: providerID)?.models ?? []
        let known = catalogModels.filter { fetchedSet.contains($0.id) }
        let knownIDs = Set(known.map(\.id))
        let unknown = uniqueFetched
            .filter { !knownIDs.contains($0) }
            .sorted()
            .map {
                LLMCatalogModel(
                    id: $0,
                    maxContextTokens: defaultFetchedMaxContextTokens,
                    supportsThinking: false
                )
            }
        return known + unknown
    }
}
