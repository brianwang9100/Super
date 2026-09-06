import Foundation

/// Common abstraction for every LLM (Large Language Model) backend. Concrete
/// conformers (e.g. `OpenAICompatibleLLMProvider` in the Chat module)
/// translate provider-specific request and response formats to and from the
/// normalized `LLMStreamEvent` stream.
public protocol LLMProvider: Sendable {
    /// Stable provider identifier used in the registry and UI ("openai",
    /// "anthropic", etc.).
    var id: String { get }
    /// User-facing label for this provider.
    var displayName: String { get }
    /// Models the provider can route to. May be loaded lazily by some
    /// conformers; this is what the model picker displays.
    var supportedModels: [LLMModel] { get }

    /// Resolve current model metadata before budgeting or compaction. Providers
    /// with asynchronous readiness fail here instead of budgeting a guessed limit.
    func resolveModel(_ model: LLMModel) async throws(LLMError) -> LLMModel

    /// Begin a streaming completion.
    ///
    /// - Parameters:
    ///   - messages: Full prompt in chronological order. Conformers prepend
    ///     any provider-required system messages themselves; callers should
    ///     supply a single leading `.system` message at most.
    ///   - model: Target model. Must be present in `supportedModels`;
    ///     conformers throw `LLMError.unsupportedModel(_:)` otherwise.
    ///   - tools: Enabled tools to advertise in this turn. Pass `[]` to
    ///     disable tool use.
    ///   - temperature: Sampling temperature (typically 0.0–2.0). Conformers
    ///     are expected to clamp to the provider's own valid range rather
    ///     than reject out-of-range values.
    /// - Returns: A throwing stream of normalized `LLMStreamEvent`s. The
    ///   stream finishes after `.messageComplete(usage:)` and throws on
    ///   transport, decoding, or provider errors.
    func stream(
        messages: [LLMMessage],
        model: LLMModel,
        tools: [LLMTool],
        temperature: Double
    ) -> AsyncThrowingStream<LLMStreamEvent, Error>

    /// Begin a streaming completion, carrying per-request `options` (cache
    /// routing keys, etc.). Semantics are identical to the 4-arg `stream(...)`;
    /// `options` only ever tunes provider-side optimizations, never the prompt.
    ///
    /// A protocol-extension default forwards to the 4-arg method and ignores
    /// `options`, so the ~dozen conformers need no change. The OpenAI Chat and
    /// Responses adapters override it to attach their host-gated routing keys.
    /// (Providers are registry-shared singletons, so the key must travel
    /// per-request rather than via the initializer.)
    ///
    /// Delegation contract for an options-aware conformer: override **this**
    /// 5-arg method as the real implementation and have its 4-arg method
    /// forward *here* — not the other way around. Callers that want caching use
    /// the 5-arg path (e.g. `ChatSession`), so a conformer whose 4-arg held the
    /// real logic would silently drop `options`.
    func stream(
        messages: [LLMMessage],
        model: LLMModel,
        tools: [LLMTool],
        temperature: Double,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<LLMStreamEvent, Error>
}

public extension LLMProvider {
    func resolveModel(_ model: LLMModel) async throws(LLMError) -> LLMModel { model }

    func stream(
        messages: [LLMMessage],
        model: LLMModel,
        tools: [LLMTool],
        temperature: Double,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        stream(messages: messages, model: model, tools: tools, temperature: temperature)
    }
}
