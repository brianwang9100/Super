import Foundation

/// Persistence boundary for per-tool enablement. Chat ships a GRDB-backed
/// conformer; tests use an in-memory one. Returning nil from
/// `isEnabled(toolID:)` means "no record yet" — the registry then keeps the
/// definition's default.
public protocol ToolEnablementStore: Sendable {
    func isEnabled(toolID: String) async throws -> Bool?
    func setEnabled(toolID: String, enabled: Bool) async throws
    func allEnabled() async throws -> [String: Bool]
}

/// Errors thrown by `ToolRegistry` operations.
public enum ToolRegistryError: Error, Sendable, Equatable {
    case unknownTool(String)
    case toolDisabled(String)
    case remoteExecutionNotConfigured(toolID: String, endpoint: String)
}

/// Actor-isolated registry of `ToolDefinition`s and the dispatcher that runs
/// them.
///
/// On `register(_:)` the registry hydrates each definition's `isEnabled`
/// from the optional `ToolEnablementStore` so user toggles survive an app
/// restart. `.remote` execution is metadata-only in M1: the registry throws
/// `remoteExecutionNotConfigured` when asked to dispatch one. Real remote
/// execution lands when a future milestone wires `RemoteHTTPToolExecutor`
/// into a `.local(...)` execution.
public actor ToolRegistry {
    private var definitions: [String: ToolDefinition] = [:]
    private let enablementStore: (any ToolEnablementStore)?

    public init(enablementStore: (any ToolEnablementStore)? = nil) {
        self.enablementStore = enablementStore
    }

    /// Register a tool.
    ///
    /// - Parameter definition: The tool, its executor, and its default
    ///   enablement. If an enablement store is wired and already has a value
    ///   for this tool, the persisted state wins over `definition.isEnabled`.
    public func register(_ definition: ToolDefinition) async {
        var resolved = definition
        if let store = enablementStore {
            if let stored = try? await store.isEnabled(toolID: definition.tool.id) {
                resolved = definition.enabled(stored)
            }
        }
        definitions[definition.tool.id] = resolved
    }

    /// Toggle a tool's enablement and persist the change to the store.
    public func setEnabled(toolID: String, enabled: Bool) async throws {
        guard let definition = definitions[toolID] else {
            throw ToolRegistryError.unknownTool(toolID)
        }
        definitions[toolID] = definition.enabled(enabled)
        try await enablementStore?.setEnabled(toolID: toolID, enabled: enabled)
    }

    public func definition(toolID: String) -> ToolDefinition? {
        definitions[toolID]
    }

    public func allDefinitions() -> [ToolDefinition] {
        Array(definitions.values).sorted(by: { $0.tool.id < $1.tool.id })
    }

    /// All enabled tools, sorted by id for stable LLM (Large Language Model)
    /// prompt assembly.
    public func enabledTools() -> [AITool] {
        definitions.values
            .filter(\.isEnabled)
            .map(\.tool)
            .sorted(by: { $0.id < $1.id })
    }

    /// Same as `enabledTools()` but takes the active provider so future
    /// milestones can filter by per-provider tool support without changing
    /// call sites. M1 returns all enabled tools regardless of provider.
    public func enabledTools(for provider: any LLMProvider) -> [AITool] {
        _ = provider
        return enabledTools()
    }

    /// Dispatch a tool call to its executor.
    ///
    /// - Parameters:
    ///   - toolID: Identifier of a previously-registered tool.
    ///   - input: Validated parameters as a JSON object. Validation is the
    ///     caller's job — this method does not check `input` against the
    ///     tool's `parameters` schema.
    /// - Returns: The executor's `ToolResult`.
    /// - Throws: `unknownTool(_:)` if `toolID` was never registered,
    ///   `toolDisabled(_:)` if the user has it turned off, or
    ///   `remoteExecutionNotConfigured(_:_:)` for `.remote` definitions
    ///   (see the type-level doc for M1 limitations).
    public func execute(toolID: String, input: [String: JSONValue]) async throws -> ToolResult {
        guard let definition = definitions[toolID] else {
            throw ToolRegistryError.unknownTool(toolID)
        }
        guard definition.isEnabled else {
            throw ToolRegistryError.toolDisabled(toolID)
        }
        switch definition.execution {
        case .local(let executor):
            return try await executor.execute(input: input)
        case .remote(let endpoint):
            throw ToolRegistryError.remoteExecutionNotConfigured(
                toolID: toolID,
                endpoint: endpoint.url.absoluteString
            )
        }
    }
}
