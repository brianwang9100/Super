/// Prompt/tool budget tier determined by context size, independent of provider family.
public enum ModelContextTier: Sendable, Equatable {
    case compact
    case full

    public static let compactCeiling = 8_192

    /// An omitted LLMModel window defaults to the compact ceiling.
    public init(maxContextTokens: Int) {
        self = maxContextTokens <= Self.compactCeiling ? .compact : .full
    }
}
