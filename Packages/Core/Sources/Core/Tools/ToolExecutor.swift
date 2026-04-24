import Foundation

/// Anything that runs a tool in response to an LLM (Large Language Model)
/// call. Conformers receive validated input as `[String: JSONValue]` and
/// return a `ToolResult`.
public protocol ToolExecutor: Sendable {
    var toolID: String { get }
    func execute(input: [String: JSONValue]) async throws -> ToolResult
}

/// Result of a tool invocation. `content` is the natural-language string the
/// LLM sees in the next turn; `artifacts` carry structured side-channel data
/// (created entity IDs, etc.) for the UI to surface without parsing the
/// natural-language content.
public struct ToolResult: Sendable, Equatable, Codable {
    public let toolID: String
    public let content: String
    public let isError: Bool
    public let artifacts: [Artifact]

    public init(
        toolID: String,
        content: String,
        isError: Bool = false,
        artifacts: [Artifact] = []
    ) {
        self.toolID = toolID
        self.content = content
        self.isError = isError
        self.artifacts = artifacts
    }

    /// Structured side-channel datum (e.g. a created todo item's id). The
    /// UI can present these as chips or links without the LLM having to
    /// embed them in the response text.
    public struct Artifact: Sendable, Equatable, Codable {
        public let type: String
        public let id: String
        public let data: [String: String]

        public init(type: String, id: String, data: [String: String] = [:]) {
            self.type = type
            self.id = id
            self.data = data
        }
    }
}
