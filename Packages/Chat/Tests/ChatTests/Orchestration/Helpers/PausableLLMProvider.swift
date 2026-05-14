import Core
import Foundation

/// Test double that hands the test direct control of the
/// AsyncThrowingStream powering `stream(...)`. Unlike `FakeLLMProvider`,
/// which drains a pre-baked event array as fast as the consumer reads,
/// this provider keeps the stream open until `yield(_:)` is called.
/// Tests use it to park `ChatSession.streamOneTurn` mid-turn — after a
/// `.thinkingDelta`, say — so they can race a `subscribe()` against the
/// live actor state without depending on timing.
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

    /// Yield a single event to the active stream. Returns as soon as the
    /// actor has handled the call — either by forwarding to the live
    /// continuation, or by buffering on `pending` when the session's
    /// `Task { ... register }` hop hasn't run yet. This does **not**
    /// synchronize on the consumer (the `ChatSession`) reading the event;
    /// tests that need that ordering should read the session's broadcast
    /// off its subscriber stream.
    func yield(_ event: LLMStreamEvent) async {
        await state.yield(event)
    }

    /// Close the active stream. Required before `ChatSession` can wind
    /// down the turn cleanly; without it, `streamOneTurn`'s for-await
    /// loop never returns and `waitUntilFinished()` hangs.
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

/// Backing actor that brokers between the producing test and the
/// consuming `ChatSession`. `register(continuation:)` runs on a `Task`
/// spawned by `stream(...)`, so it races against any `yield(_:)` the
/// test issues immediately after `session.send(...)`. `pending` is the
/// safety net: a `yield` that wins the race lands there and is flushed
/// the moment `register` runs. Once the continuation is cached,
/// subsequent yields forward straight through.
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
