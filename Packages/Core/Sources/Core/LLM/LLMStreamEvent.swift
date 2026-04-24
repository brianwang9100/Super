import Foundation

/// Normalized streaming event emitted by every LLM (Large Language Model)
/// provider, regardless of native wire format.
///
/// `thinkingDelta` is intentionally distinct from `textDelta` because some
/// providers (DeepSeek R-series, OpenAI o-series) emit reasoning tokens on a
/// separate channel. The Chat UI renders them in a collapsible block with
/// different styling.
public enum LLMStreamEvent: Sendable, Equatable {
    case messageStart(id: String, model: String)
    case contentBlockStart(index: Int, type: ContentBlockType)
    case textDelta(index: Int, text: String)
    case thinkingDelta(index: Int, text: String)
    /// Tool invocation requested by the model. `input` is conventionally a
    /// `JSONValue.object` whose keys match the tool's parameter schema —
    /// kept as a single `JSONValue` (rather than `[String: JSONValue]`) so
    /// downstream serializers can encode/decode the payload in one hop.
    case toolUse(index: Int, id: String, name: String, input: JSONValue)
    case contentBlockStop(index: Int)
    case messageComplete(usage: TokenUsage)
    case error(LLMError)

    /// Kind of a content block, communicated at the start of a block.
    public enum ContentBlockType: String, Sendable, Equatable, Codable {
        case text
        case thinking
        case toolUse
    }
}
