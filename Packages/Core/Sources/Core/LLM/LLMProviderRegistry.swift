import Foundation

/// Errors thrown by `LLMProviderRegistry` operations.
public enum LLMProviderRegistryError: Error, Sendable, Equatable {
    case unknownProvider(String)
    case noActiveProvider
}

/// Actor-isolated registry of LLM (Large Language Model) providers.
///
/// The first provider registered becomes active automatically; subsequent
/// `setActive(id:)` calls swap which provider new chat turns route through.
/// Tracking exactly one active provider matches how the Settings > Models
/// pane is shaped — the user picks one model configuration at a time.
public actor LLMProviderRegistry {
    private var providers: [String: any LLMProvider] = [:]
    private var activeProviderID: String?

    public init() {}

    /// Add a provider. The first registration becomes active automatically.
    public func register(_ provider: any LLMProvider) {
        providers[provider.id] = provider
        if activeProviderID == nil {
            activeProviderID = provider.id
        }
    }

    /// Remove a provider by id. If it was active, picks the next provider
    /// (alphabetical by id) as a stable fallback.
    public func unregister(id: String) {
        providers.removeValue(forKey: id)
        if activeProviderID == id {
            activeProviderID = providers.keys.sorted().first
        }
    }

    /// Switch the active provider. Throws if `id` is not registered.
    public func setActive(id: String) throws {
        guard providers[id] != nil else {
            throw LLMProviderRegistryError.unknownProvider(id)
        }
        activeProviderID = id
    }

    /// Currently active provider, or nil if none is registered.
    public func active() -> (any LLMProvider)? {
        guard let id = activeProviderID else { return nil }
        return providers[id]
    }

    /// Like `active()` but throws when no provider is registered — useful in
    /// orchestration code where missing config should surface an error.
    public func requireActive() throws -> any LLMProvider {
        guard let provider = active() else { throw LLMProviderRegistryError.noActiveProvider }
        return provider
    }

    public func provider(id: String) -> (any LLMProvider)? {
        providers[id]
    }

    /// The registered provider whose `supportedModels` include `modelId`
    /// (the upstream model identifier, e.g. `claude-opus-4-7`), or nil when
    /// no registered provider serves that model. Providers are keyed by
    /// record UUID, so a model id requires a scan rather than a direct
    /// lookup — used wherever a caller holds a model id and needs the
    /// provider that can stream it (the composer's active-provider promotion,
    /// the headless title summarizer).
    ///
    /// Scans in id-sorted order so the result is deterministic if two rows
    /// ever expose the same model id (matching the prior `allProviders()`
    /// scan this replaced).
    public func provider(forModelId modelId: String) -> (any LLMProvider)? {
        providers.values
            .sorted { $0.id < $1.id }
            .first { $0.supportedModels.contains { $0.id == modelId } }
    }

    /// All providers sorted by id for stable enumeration in settings panes.
    public func allProviders() -> [any LLMProvider] {
        providers.values.sorted(by: { $0.id < $1.id })
    }

    public func activeID() -> String? {
        activeProviderID
    }
}
