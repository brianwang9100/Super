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

    /// Options never change the prompt. Built-in remote adapters report unsuccessful or
    /// unverified native completion when requiresCompleteResponse is set. Reject any error
    /// even if messageComplete follows. The default ignores options; options-aware conformers
    /// implement this overload and forward the four-argument method here with .none.
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
