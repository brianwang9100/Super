/// Classifies a model by how much room its context window leaves for an actual
/// conversation, so the orchestrator can swap in a leaner system prompt + tool
/// set for small-window models (the on-device Apple Foundation Model, or any
/// future small local model) without touching the experience on large-window
/// cloud/BYOK models.
///
/// Keyed on the window size rather than the provider kind so it generalizes:
/// a 4096- or 8192-token on-device model is `.compact`; every cloud/BYOK model
/// (≥ 32K) is `.full` and assembles byte-identically to before this existed.
public enum ModelContextTier: Sendable, Equatable {
    /// Small window — lean briefings + a reduced tool set to leave room for the
    /// conversation.
    case compact
    /// Ample window — the full briefings and tool set.
    case full

    /// The largest window that still counts as `.compact`. The on-device AFM
    /// reports 4096 on most devices and 8192 on newer-device tiers (iOS 27),
    /// so the threshold covers both; the smallest cloud/BYOK window in the
    /// catalog is 32K, comfortably above it.
    public static let compactCeiling = 8_192

    /// Classify by the model's advertised context window.
    ///
    /// Keys purely on the declared window. `LLMModel.maxContextTokens` defaults
    /// to `8_192` (== `compactCeiling`), so an `LLMModel` built *without* an
    /// explicit window classifies `.compact` — only debug/test fixtures do that;
    /// every production model carries a real window from the catalog or the
    /// persisted `modelConfiguration` row.
    public init(maxContextTokens: Int) {
        self = maxContextTokens <= Self.compactCeiling ? .compact : .full
    }
}
