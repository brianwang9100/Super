import Core
import Foundation

/// Exposes manual event delivery and keeps the stream open until finish().
final class PausableLLMProvider: LLMProvider, Sendable {
    let id: String
    let displayName: String
    let supportedModels: [LLMModel]

    private let state: PausableLLMProviderState

    init(id: String = "pausable", model: LLMModel) {
        self.id = id
        self.displayName = "Pausable LLM"
        self.supportedModels = [model]
        self.state = PausableLLMProviderState()
    }

    /// Buffers until registration. This does not wait for consumer processing;
    /// read the session broadcast when the test needs that ordering.
    func yield(_ event: LLMStreamEvent) async {
        await state.yield(event)
    }

    /// Close before waitUntilFinished() or the session remains in its for-await loop.
    func finish() async {
        await state.finish()
    }

    func stream(
        messages: [LLMMessage],
        model: LLMModel,
        tools: [LLMTool],
        temperature: Double
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let stateRef = state
        return AsyncThrowingStream { continuation in
            Task { await stateRef.register(continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await stateRef.clearContinuation() }
            }
        }
    }
}

// Registration runs in a separate task; buffer yields that arrive first.
private actor PausableLLMProviderState {
    private var continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation?
    private var pending: [LLMStreamEvent] = []
    private var finished = false

    func register(continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation) {
        for event in pending { continuation.yield(event) }
        pending.removeAll()
        if finished {
            continuation.finish()
            return
        }
        self.continuation = continuation
    }

    func clearContinuation() {
        continuation = nil
    }

    func yield(_ event: LLMStreamEvent) {
        if let continuation {
            continuation.yield(event)
        } else {
            pending.append(event)
        }
    }

    func finish() {
        finished = true
        continuation?.finish()
        continuation = nil
    }
}
