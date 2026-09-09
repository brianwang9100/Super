import Foundation

public struct ToolRegistration: Sendable {
    public let tool: LLMTool
    public let execution: ToolExecution
    public let isEnabled: Bool

    public init(tool: LLMTool, execution: ToolExecution, isEnabled: Bool = true) {
        self.tool = tool
        self.execution = execution
        self.isEnabled = isEnabled
    }

    public func enabled(_ value: Bool) -> ToolRegistration {
        ToolRegistration(tool: tool, execution: execution, isEnabled: value)
    }
}

/// Remote metadata alone cannot dispatch; register a local executor for the endpoint.
public enum ToolExecution: Sendable {
    case local(any ToolExecutor)
    case remote(RemoteToolEndpoint)
}
