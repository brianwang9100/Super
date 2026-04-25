import Core
import Foundation

/// Test double for `LLMProvider`. Each call to `stream(...)` consumes the
/// next enqueued event sequence and replays it as the AsyncThrowingStream.
/// The provider records every request so tests can assert message
/// assembly, tool list filtering, and temperature plumbing.
final class FakeLLMProvider: LLMProvider {
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
        let captured = CapturedLLMRequest(
            modelID: model.id,
            messages: messages,
            tools: tools,
            temperature: temperature
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

/// A snapshot of what the session sent into `stream(...)` for one turn.
struct CapturedLLMRequest: Sendable, Equatable {
    let modelID: String
    let messages: [LLMMessage]
    let tools: [LLMTool]
    let temperature: Double
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
            // Hand the session a benign terminator so tests that forget
            // to enqueue still get a clean stream rather than hanging.
            return [
                .messageStart(id: "fake-empty", model: request.modelID),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ]
        }
        return pending.removeFirst()
    }
}
