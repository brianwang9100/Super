import Foundation

public protocol ToolExecutor: Sendable {
    var toolID: String { get }
    func execute(input: [String: JSONValue]) async throws -> ToolResult
}

/// content goes to the model; structured artifacts go to UI without parsing prose.
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
