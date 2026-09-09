import Core

/// Tool schemas dominate small-window prompt budgets; full-tier models keep the complete tool set.
enum CompactToolPolicy {
    // Keep lookup for grounding and memory for personalization. The prompt already supplies
    // the date, and heavy annotation/note/highlight actions remain available in the reader.
    static let droppedToolNames: Set<String> = [
        "time.now",
        "bible.annotate",
        "bible.note",
        "bible.highlight",
    ]

    /// Shorten description text only; preserve schema shape and execution validation.
    static func filter(_ tools: [LLMTool], tier: ModelContextTier) -> [LLMTool] {
        guard tier == .compact else { return tools }
        return tools
            .filter { !droppedToolNames.contains($0.name) }
            .map { tool in
                LLMTool(
                    id: tool.id,
                    name: tool.name,
                    description: tool.compactDescription ?? tool.description,
                    category: tool.category,
                    parameters: tool.parameters.map(compacted),
                    appletId: tool.appletId,
                    displayName: tool.displayName,
                    summary: tool.summary,
                    compactDescription: tool.compactDescription
                )
            }
    }

    // Nested members stay unchanged because compact-tier providers flatten them to scalars.
    private static func compacted(_ parameter: LLMToolParameter) -> LLMToolParameter {
        guard let compact = parameter.compactDescription else { return parameter }
        return LLMToolParameter(
            name: parameter.name,
            type: parameter.type,
            description: compact,
            isRequired: parameter.isRequired,
            enumValues: parameter.enumValues,
            valueSchema: parameter.valueSchema,
            compactDescription: compact
        )
    }
}
