import Chat
import Core
import Foundation

/// Saves on first send so unused drafts leave no database row. `onPersisted` follows
/// `ensureSaved`, allowing the sidebar to promote the draft into its persisted list.
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

    /// Flush defensively if retry is reached before send; both paths share the one-shot save.
    func retry(model: LLMModel) async -> AsyncStream<ChatEvent> {
        await flushEnsureSavedIfPending()
        return await inner.retry(model: model)
    }

    /// Clear each callback before awaiting it so reentrant calls cannot invoke it twice.
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
        // An unpersisted draft has no live turn; the inner driver already handles that case.
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
