import Foundation

/// Nil enablement means no saved choice; preserve the registration default.
public protocol ToolEnablementRepository: Sendable {
    func isEnabled(toolID: String) async throws -> Bool?
    func setEnabled(toolID: String, enabled: Bool) async throws
    func allEnabled() async throws -> [String: Bool]
}

public enum ToolRegistryError: Error, Sendable, Equatable {
    case unknownTool(String)
    case toolDisabled(String)
    case remoteExecutionNotConfigured(toolID: String, endpoint: String)
}

/// Remote registrations are metadata only. Dispatch requires a local executor,
/// including for HTTP-backed tools.
public actor ToolRegistry {
    private var registrations: [String: ToolRegistration] = [:]
    private let enablementRepository: (any ToolEnablementRepository)?

    public init(enablementRepository: (any ToolEnablementRepository)? = nil) {
        self.enablementRepository = enablementRepository
    }

    /// Persisted enablement overrides the registration default when available.
    public func register(_ registration: ToolRegistration) async {
        var resolved = registration
        if let repository = enablementRepository {
            if let stored = try? await repository.isEnabled(toolID: registration.tool.id) {
                resolved = registration.enabled(stored)
            }
        }
        registrations[registration.tool.id] = resolved
    }

    /// Persists enablement as well as updating the live registration.
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

    /// Sorted by ID for stable prompt assembly.
    public func enabledTools() -> [LLMTool] {
        registrations.values
            .filter(\.isEnabled)
            .map(\.tool)
            .sorted(by: { $0.id < $1.id })
    }

    /// Provider-aware seam; all providers currently receive the enabled set.
    public func enabledTools(for provider: any LLMProvider) -> [LLMTool] {
        _ = provider
        return enabledTools()
    }

    /// Caller validates input against the schema. Throws for unknown/disabled tools
    /// or remote registrations without a local executor; executor errors propagate.
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
