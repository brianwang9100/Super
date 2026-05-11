import Foundation

/// Single record stored in `ToolRegistry`: an `LLMTool` plus how it executes
/// plus whether the user has it enabled.
///
/// Splitting `tool` from `execution` lets us swap in a
/// `RemoteHTTPToolExecutor` later without touching the `LLMTool` schema the
/// LLM (Large Language Model) receives.
public struct ToolRegistration: Sendable {
    public let tool: LLMTool
    public let execution: ToolExecution
    public let isEnabled: Bool

    public init(tool: LLMTool, execution: ToolExecution, isEnabled: Bool = true) {
        self.tool = tool
        self.execution = execution
        self.isEnabled = isEnabled
    }

    /// Returns a copy with a new enablement state. Used by the registry when
    /// hydrating from a `ToolEnablementRepository` and on user toggles.
    public func enabled(_ value: Bool) -> ToolRegistration {
        ToolRegistration(tool: tool, execution: execution, isEnabled: value)
    }
}

/// Where a tool runs. `.remote` is metadata-only in M1 — the `ToolRegistry`
/// throws `remoteExecutionNotConfigured` rather than dispatching it.
public enum ToolExecution: Sendable {
    case local(any ToolExecutor)
    case remote(RemoteToolEndpoint)
}
