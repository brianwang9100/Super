import Foundation

/// Persistence boundary for per-tool enablement. Chat ships a GRDB-backed
/// conformer; tests use an in-memory one. Returning nil from
/// `isEnabled(toolID:)` means "no record yet" — the registry then keeps the
/// registration's default.
public protocol ToolEnablementRepository: Sendable {
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

/// Actor-isolated registry of `ToolRegistration`s and the dispatcher that runs
/// them.
///
/// On `register(_:)` the registry hydrates each registration's `isEnabled`
/// from the optional `ToolEnablementRepository` so user toggles survive an app
/// restart. `.remote` execution is metadata-only in M1: the registry throws
/// `remoteExecutionNotConfigured` when asked to dispatch one. Real remote
/// execution lands when a future milestone wires `RemoteHTTPToolExecutor`
/// into a `.local(...)` execution.
public actor ToolRegistry {
    private var registrations: [String: ToolRegistration] = [:]
    private let enablementRepository: (any ToolEnablementRepository)?

    public init(enablementRepository: (any ToolEnablementRepository)? = nil) {
        self.enablementRepository = enablementRepository
    }

    /// Register a tool.
    ///
    /// - Parameter registration: The tool, its executor, and its default
    ///   enablement. If an enablement repository is wired and already has a
    ///   value for this tool, the persisted state wins over
    ///   `registration.isEnabled`.
    public func register(_ registration: ToolRegistration) async {
        var resolved = registration
        if let repository = enablementRepository {
            if let stored = try? await repository.isEnabled(toolID: registration.tool.id) {
                resolved = registration.enabled(stored)
            }
        }
        registrations[registration.tool.id] = resolved
    }

    /// Toggle a tool's enablement and persist the change to the repository.
    public func setEnabled(toolID: String, enabled: Bool) async throws {
        guard let registration = registrations[toolID] else {
            throw ToolRegistryError.unknownTool(toolID)
        }
        registrations[toolID] = registration.enabled(enabled)
        try await enablementRepository?.setEnabled(toolID: toolID, enabled: enabled)
    }

    public func registration(toolID: String) -> ToolRegistration? {
        registrations[toolID]
    }

    public func allRegistrations() -> [ToolRegistration] {
        Array(registrations.values).sorted(by: { $0.tool.id < $1.tool.id })
    }

    /// All enabled tools, sorted by id for stable LLM (Large Language Model)
    /// prompt assembly.
    public func enabledTools() -> [LLMTool] {
        registrations.values
            .filter(\.isEnabled)
            .map(\.tool)
            .sorted(by: { $0.id < $1.id })
    }

    /// Same as `enabledTools()` but takes the active provider so future
    /// milestones can filter by per-provider tool support without changing
    /// call sites. M1 returns all enabled tools regardless of provider.
    public func enabledTools(for provider: any LLMProvider) -> [LLMTool] {
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
    ///   `remoteExecutionNotConfigured(_:_:)` for `.remote` registrations
    ///   (see the type-level doc for M1 limitations).
    public func execute(toolID: String, input: [String: JSONValue]) async throws -> ToolResult {
        guard let registration = registrations[toolID] else {
            throw ToolRegistryError.unknownTool(toolID)
        }
        guard registration.isEnabled else {
            throw ToolRegistryError.toolDisabled(toolID)
        }
        switch registration.execution {
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
