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
    /// Kept on compact: `bible.lookup` (grounding — every scripture answer
    /// reads or searches through it) and `memory` (cross-conversation
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
    /// shrinks each survivor's schema to its hand-authored compact variants —
    /// the tool-level `compactDescription` *and* each parameter's
    /// `compactDescription` (when present). Parameter descriptions count toward
    /// the schema-token budget too (see `TokenEstimator.schemaText`), and across
    /// the kept set the full descriptions are several thousand characters a
    /// 4096-token window can't afford. Returns the set unchanged on `.full`.
    /// Only the *description* text shrinks — names, types, `enumValues`,
    /// `isRequired`, and `valueSchema` are untouched, so execution-side
    /// validation is unaffected.
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

    /// Swap a parameter's `description` for its `compactDescription` when it
    /// ships one, leaving every schema-shaping field (`type`, `enumValues`,
    /// `isRequired`, `valueSchema`) untouched. Nested object/array members are
    /// left as-is: on the compact tier the provider flattens them to scalars,
    /// so they aren't worth a per-member compact pass.
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
