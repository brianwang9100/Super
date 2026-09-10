import Core

/// Use short display copy; full tool descriptions and schemas exceed the small suggestion budget.
public enum SuggestionCapabilities {
    public static func compact(from tools: [LLMTool], limit: Int = 6) -> [String] {
        tools.prefix(limit).map { tool in
            let name = tool.displayName ?? tool.name
            if let summary = tool.summary, !summary.isEmpty {
                return "\(name): \(summary)"
            }
            return name
        }
    }
}
