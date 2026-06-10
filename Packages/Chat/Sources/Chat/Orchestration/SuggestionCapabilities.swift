import Core

/// Builds the compact, schema-free capability lines fed to the on-device
/// suggestion generator. AFM has a tiny (~4k-token) context window, so this
/// deliberately uses only each tool's user-facing `displayName`/`name` and
/// one-line `summary` — **never** the LLM-facing `description` or the parameter
/// schema, which are large and would blow the budget.
public enum SuggestionCapabilities {
    /// One short line per tool: `displayName ?? name`, plus `: summary` when the
    /// tool has one. Capped to `limit` so a large tool roster can't bloat the
    /// prompt. Order is preserved (the caller passes tools in a stable order).
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
