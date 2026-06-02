import Chat
import Core
import Foundation

/// Defers persistence of a `ConversationRecord` until the user actually
/// sends their first message. Wraps the production
/// `LiveChatSessionDriver` and runs `ensureSaved` exactly once on the
/// first `send(...)` call — until then the conversation lives only in
/// memory, so an unused "New Chat" tap leaves no orphan row in the DB.
///
/// `onPersisted` fires immediately after `ensureSaved` so the host can
/// refresh the sidebar (the draft row promotes to a normal DB-backed
/// row in the next list pull).
///
/// Modeled as an actor so the once-only flag is race-free under
/// concurrent sends — though in practice the composer is the only
/// caller and is itself main-actor isolated.
actor LazyConversationDriver: ChatSessionDriver {
    private let inner: any ChatSessionDriver
    private var ensureSaved: (@Sendable () async -> Void)?
    private var onPersisted: (@Sendable () async -> Void)?

    init(
        inner: any ChatSessionDriver,
        ensureSaved: @escaping @Sendable () async -> Void,
        onPersisted: @escaping @Sendable () async -> Void
    ) {
        self.inner = inner
        self.ensureSaved = ensureSaved
        self.onPersisted = onPersisted
    }

    func send(text: String, model: LLMModel, references: [RecordReference]) async -> AsyncStream<ChatEvent> {
        await flushEnsureSavedIfPending()
        return await inner.send(text: text, model: model, references: references)
    }

    /// In practice retry is only reachable after an error from a prior
    /// send, so `ensureSaved` is already `nil`. Flush defensively anyway
    /// so a future UI path that surfaces Retry without a preceding
    /// `send` (restored session, deeplink, etc.) doesn't operate against
    /// an orphaned `conversationId`. The flush is idempotent — once
    /// `ensureSaved` is consumed, subsequent calls short-circuit.
    func retry(model: LLMModel) async -> AsyncStream<ChatEvent> {
        await flushEnsureSavedIfPending()
        return await inner.retry(model: model)
    }

    /// Run the one-shot `ensureSaved` + `onPersisted` flush if it hasn't
    /// fired yet. Idempotent — the second call short-circuits because
    /// both closures have been niled out.
    private func flushEnsureSavedIfPending() async {
        guard let pending = ensureSaved else { return }
        ensureSaved = nil
        await pending()
        if let notify = onPersisted {
            onPersisted = nil
            await notify()
        }
    }

    func subscribe() async -> (snapshot: ChatSession.LiveTurnSnapshot?, stream: AsyncStream<ChatEvent>) {
        // A draft conversation that hasn't been persisted has no session
        // either, but the inner driver can answer either way: the live
        // session returns (nil, immediately-finished) when no turn is in
        // flight. No reason to gate this on `ensureSaved`.
        await inner.subscribe()
    }

    func cancel() async {
        await inner.cancel()
    }

    func confirmToolCall(id: String) async {
        await inner.confirmToolCall(id: id)
    }

    func skipToolCall(id: String) async {
        await inner.skipToolCall(id: id)
    }
}
