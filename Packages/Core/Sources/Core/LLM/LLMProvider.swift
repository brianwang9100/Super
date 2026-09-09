import Foundation

public protocol LLMProvider: Sendable {
    /// Stable configuration identity used for registry selection.
    var id: String { get }
    var displayName: String { get }
    var supportedModels: [LLMModel] { get }

    /// Supply leading system instructions and chronological history, an advertised
    /// model, and an empty tools array to disable tools. Temperature handling is
    /// adapter-specific. Consumers must handle both error events and thrown stream
    /// errors; production adapters normally emit messageComplete after error events.
    func stream(
        messages: [LLMMessage],
        model: LLMModel,
        tools: [LLMTool],
        temperature: Double
    ) -> AsyncThrowingStream<LLMStreamEvent, Error>

    /// Options tune per-request provider optimizations without changing prompt content.
    /// The default ignores them. Options-aware conformers implement this overload and
    /// forward the four-argument overload here, or callers silently lose their options.
    /// Keep routing keys per request because provider instances are shared.
    func stream(
        messages: [LLMMessage],
        model: LLMModel,
        tools: [LLMTool],
        temperature: Double,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<LLMStreamEvent, Error>
}

public extension LLMProvider {
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
