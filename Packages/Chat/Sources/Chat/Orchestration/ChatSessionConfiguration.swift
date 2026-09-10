public struct ChatSessionConfiguration: Sendable {
    public enum ToolPolicy: Sendable {
        case enabled
        case disabled
    }

    public static let defaultTemperature = 1.0

    public let tools: ToolPolicy
    /// Requires verified terminal completion through EOF. With tools disabled,
    /// a successful response must contain non-whitespace text.
    public let requiresCompleteResponse: Bool

    public init(tools: ToolPolicy = .enabled, requiresCompleteResponse: Bool = false) {
        self.tools = tools
        self.requiresCompleteResponse = requiresCompleteResponse
    }
}
