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
    ///
    /// `signature` is an opaque provider continuation token attached to the
    /// call that MUST be echoed back unchanged on the next turn — today this
    /// is Gemini's `thoughtSignature` (thinking models reject a replayed
    /// `functionCall` that omits it with HTTP 400). `nil` for providers that
    /// don't emit one.
    case toolUse(index: Int, id: String, name: String, input: JSONValue, signature: String?)
    /// Integrity signature for this turn's thinking block (Anthropic
    /// `signature_delta`). Emitted at most once per turn, after the thinking
    /// content has streamed; consumers persist it alongside the thinking text
    /// so the block can be replayed verbatim on the next tool-loop request
    /// (the Messages API 400s a rebuilt last-assistant turn without it).
    /// Never emitted for a turn containing `redacted_thinking` — those turns
    /// are not replayable from our persistence model.
    case thinkingSignature(index: Int, signature: String)
    case contentBlockStop(index: Int)
    /// A native server-side web search has started for the given query. Drives a
    /// "Searching the web…" affordance independently of whether citations arrive.
    case searchStarted(query: String)
    /// Normalized citations parsed from the stream. May arrive more than once in a
    /// turn; consumers accumulate and dedupe on `url`.
    case citations([SourceCitation])
    /// Provider-supplied search-attribution HTML that MUST be rendered unmodified
    /// and kept visible (Gemini "Google Search Suggestions"). Other providers
    /// never emit this case.
    case searchSuggestionsHTML(String)
    case messageComplete(usage: TokenUsage)
    case error(LLMError)

    /// Kind of a content block, communicated at the start of a block.
    public enum ContentBlockType: String, Sendable, Equatable, Codable {
        case text
        case thinking
        case toolUse
    }
}
