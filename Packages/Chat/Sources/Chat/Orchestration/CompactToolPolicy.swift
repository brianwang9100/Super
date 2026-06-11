import Core

/// Decides which tools a small-window (`.compact`) model receives. The
/// on-device Apple Foundation Model has a ~4096-token window, and each tool's
/// schema — serialized in full by the provider on every request — is the
/// dominant cost (an AFM turn measured ~11k tokens against a ~3k prose
/// estimate, almost all of it tool schemas). Dropping the heaviest/lowest-value
/// tools on the compact tier is the single biggest lever for keeping room for
/// the actual conversation.
///
/// `.full`-tier models (every cloud/BYOK model, ≥ 32K window) keep the entire
/// tool set unchanged.
enum CompactToolPolicy {
    /// Wire names (`LLMTool.name`) dropped from the request on the compact
    /// tier. **This is the one knob to tune the on-device tool set.**
    ///
    /// Kept on compact: `bible.read` + `bible.search` (grounding — every
    /// scripture answer depends on them) and `memory` (cross-conversation
    /// personalization, surfaced every turn anyway). Dropped: `time.now`
    /// (the date is already in the prompt context), and the `bible.annotate`
    /// / `bible.note` write tools (heavy schemas; both reachable from the
    /// reader UI, and bulk annotation runs through its own engine, not chat).
    static let droppedToolNames: Set<String> = [
        "time.now",
        "bible.annotate",
        "bible.note",
    ]

    /// Filter `tools` for `tier`: on `.compact`, drops `droppedToolNames` and
    /// swaps each survivor's LLM-facing `description` for its hand-authored
    /// `compactDescription` (when the tool ships one) — the full descriptions
    /// alone total ~3.5k characters across the kept set, which a 4096-token
    /// window can't afford. Returns the set unchanged on `.full`. Parameter
    /// schemas are never altered, so execution-side validation is unaffected.
    static func filter(_ tools: [LLMTool], tier: ModelContextTier) -> [LLMTool] {
        guard tier == .compact else { return tools }
        return tools
            .filter { !droppedToolNames.contains($0.name) }
            .map { tool in
                guard let compact = tool.compactDescription else { return tool }
                return LLMTool(
                    id: tool.id,
                    name: tool.name,
                    description: compact,
                    category: tool.category,
                    parameters: tool.parameters,
                    appletId: tool.appletId,
                    displayName: tool.displayName,
                    summary: tool.summary,
                    compactDescription: compact
                )
            }
    }
}
