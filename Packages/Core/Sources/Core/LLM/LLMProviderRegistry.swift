import Foundation

public enum LLMProviderRegistryError: Error, Sendable, Equatable {
    case unknownProvider(String)
    case noActiveProvider
}

public actor LLMProviderRegistry {
    private var providers: [String: any LLMProvider] = [:]
    private var activeProviderID: String?

    public init() {}

    /// The first registration becomes active automatically.
    public func register(_ provider: any LLMProvider) {
        providers[provider.id] = provider
        if activeProviderID == nil {
            activeProviderID = provider.id
        }
    }

    /// Removing the active provider selects the remaining provider with the alphabetically first ID.
    public func unregister(id: String) {
        providers.removeValue(forKey: id)
        if activeProviderID == id {
            activeProviderID = providers.keys.sorted().first
        }
    }

    /// Throws for an unregistered ID.
    public func setActive(id: String) throws {
        guard providers[id] != nil else {
            throw LLMProviderRegistryError.unknownProvider(id)
        }
        activeProviderID = id
    }

    public func active() -> (any LLMProvider)? {
        guard let id = activeProviderID else { return nil }
        return providers[id]
    }

    public func requireActive() throws -> any LLMProvider {
        guard let provider = active() else { throw LLMProviderRegistryError.noActiveProvider }
        return provider
    }

    public func provider(id: String) -> (any LLMProvider)? {
        providers[id]
    }

    /// Returns the first match in provider-ID order, or nil. Upstream model IDs are
    /// not unique across configurations; use provider(id:) for a specific selection.
    public func provider(forModelId modelId: String) -> (any LLMProvider)? {
        providers.values
            .sorted { $0.id < $1.id }
            .first { $0.supportedModels.contains { $0.id == modelId } }
    }

    /// Sorted by provider ID.
    public func allProviders() -> [any LLMProvider] {
        providers.values.sorted(by: { $0.id < $1.id })
    }

    public func activeID() -> String? {
        activeProviderID
    }
}
