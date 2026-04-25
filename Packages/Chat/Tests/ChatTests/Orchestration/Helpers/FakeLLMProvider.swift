import Core
import Foundation

/// Test double for `LLMProvider`. Each call to `stream(...)` consumes the
/// next enqueued event sequence and replays it as the AsyncThrowingStream.
/// The provider records every request so tests can assert message
/// assembly, tool list filtering, and temperature plumbing.
///
/// Strict by design: a `stream(...)` call with no enqueued script crashes
/// via `fatalError` rather than handing back a benign empty response. A
/// silent fallback would let "session loops one extra turn" or "test
/// forgot to script the second turn" bugs hide in green test runs.
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
            fatalError("FakeLLMProvider received a stream(...) call with no enqueued script — test misconfigured")
        }
        return pending.removeFirst()
    }
}
