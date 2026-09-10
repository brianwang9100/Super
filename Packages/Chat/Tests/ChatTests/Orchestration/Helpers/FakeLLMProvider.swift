import Core
import Foundation

/// Consumes one script per request; unscripted calls trap so extra tool-loop
/// iterations cannot silently pass tests.
final class FakeLLMProvider: LLMProvider, Sendable {
    let id: String
    let displayName: String
    let supportedModels: [LLMModel]

    private let state: FakeLLMProviderState

    init(id: String = "fake", model: LLMModel) {
        self.id = id
        self.displayName = "Fake LLM"
        self.supportedModels = [model]
        self.state = FakeLLMProviderState()
    }

    func enqueue(_ events: [LLMStreamEvent]) async {
        await state.enqueue(events)
    }

    func capturedRequests() async -> [CapturedLLMRequest] {
        await state.captured()
    }

    func stream(
        messages: [LLMMessage],
        model: LLMModel,
        tools: [LLMTool],
        temperature: Double
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        stream(messages: messages, model: model, tools: tools, temperature: temperature, options: .none)
    }

    // Capture this overload because the protocol default discards request options.
    func stream(
        messages: [LLMMessage],
        model: LLMModel,
        tools: [LLMTool],
        temperature: Double,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let captured = CapturedLLMRequest(
            modelID: model.id,
            messages: messages,
            tools: tools,
            temperature: temperature,
            options: options
        )
        let stateRef = state
        return AsyncThrowingStream { continuation in
            let task = Task {
                let events = await stateRef.consume(captured)
                for event in events {
                    if Task.isCancelled { break }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct CapturedLLMRequest: Sendable, Equatable {
    let modelID: String
    let messages: [LLMMessage]
    let tools: [LLMTool]
    let temperature: Double
    let options: LLMRequestOptions

    init(
        modelID: String,
        messages: [LLMMessage],
        tools: [LLMTool],
        temperature: Double,
        options: LLMRequestOptions = .none
    ) {
        self.modelID = modelID
        self.messages = messages
        self.tools = tools
        self.temperature = temperature
        self.options = options
    }
}

private actor FakeLLMProviderState {
    private var pending: [[LLMStreamEvent]] = []
    private var capturedRequests: [CapturedLLMRequest] = []

    func enqueue(_ events: [LLMStreamEvent]) {
        pending.append(events)
    }

    func captured() -> [CapturedLLMRequest] { capturedRequests }

    func consume(_ request: CapturedLLMRequest) -> [LLMStreamEvent] {
        capturedRequests.append(request)
        guard !pending.isEmpty else {
            fatalError("FakeLLMProvider received a stream(...) call with no enqueued script — test misconfigured")
        }
        return pending.removeFirst()
    }
}
