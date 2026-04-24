import Foundation

/// Single record stored in `ToolRegistry`: an `AITool` plus how it executes
/// plus whether the user has it enabled.
///
/// Splitting `tool` from `execution` lets us swap in a
/// `RemoteHTTPToolExecutor` later without touching the `AITool` schema the
/// LLM (Large Language Model) receives.
public struct ToolDefinition: Sendable {
    public let tool: AITool
    public let execution: ToolExecution
    public let isEnabled: Bool

    public init(tool: AITool, execution: ToolExecution, isEnabled: Bool = true) {
        self.tool = tool
        self.execution = execution
        self.isEnabled = isEnabled
    }

    /// Returns a copy with a new enablement state. Used by the registry when
    /// hydrating from a `ToolEnablementStore` and on user toggles.
    public func enabled(_ value: Bool) -> ToolDefinition {
        ToolDefinition(tool: tool, execution: execution, isEnabled: value)
    }
}

/// Where a tool runs. `.remote` is metadata-only in M1 — the `ToolRegistry`
/// throws `remoteExecutionNotConfigured` rather than dispatching it.
public enum ToolExecution: Sendable {
    case local(any ToolExecutor)
    case remote(RemoteToolEndpoint)
}
