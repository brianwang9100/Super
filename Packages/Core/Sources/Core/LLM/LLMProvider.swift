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
}
