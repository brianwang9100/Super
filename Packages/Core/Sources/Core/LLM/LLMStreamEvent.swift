import Foundation

public enum LLMStreamEvent: Sendable, Equatable {
    case messageStart(id: String, model: String)
    case contentBlockStart(index: Int, type: ContentBlockType)
    case textDelta(index: Int, text: String)
    case thinkingDelta(index: Int, text: String)
    /// input conventionally matches the tool's object schema. Echo opaque signature
        /// unchanged on replay; Gemini thinking calls reject missing thought signatures.
    case toolUse(index: Int, id: String, name: String, input: JSONValue, signature: String?)
    /// Persist unmodified for Anthropic thinking replay. At most once after thinking;
        /// omitted for redacted-thinking turns, which this persistence model cannot replay.
    case thinkingSignature(index: Int, signature: String)
    case contentBlockStop(index: Int)
    /// Search activity can begin without producing citations.
    case searchStarted(query: String)
    /// May arrive repeatedly; consumers accumulate and deduplicate by URL.
    case citations([SourceCitation])
    /// Gemini attribution HTML must remain visible and render unmodified.
    case searchSuggestionsHTML(String)
    case messageComplete(usage: TokenUsage)
    case error(LLMError)

    public enum ContentBlockType: String, Sendable, Equatable, Codable {
        case text
        case thinking
        case toolUse
    }
}
