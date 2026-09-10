import Core
import Foundation

/// Fix temperature here because ChatSession's default argument does not satisfy
/// ChatSessionDriver's shorter protocol signature.
public struct LiveChatSessionDriver: ChatSessionDriver {
    private let session: ChatSession
    private let temperature: Double

    public init(session: ChatSession, temperature: Double = 1.0) {
        self.session = session
        self.temperature = temperature
    }

    public func send(
        text: String,
        model: LLMModel,
        references: [RecordReference]
    ) async -> AsyncStream<ChatEvent> {
        await session.send(text: text, model: model, references: references, temperature: temperature)
    }

    public func retry(model: LLMModel) async -> AsyncStream<ChatEvent> {
        await session.retry(model: model, temperature: temperature)
    }

    public func subscribe() async -> (snapshot: ChatSession.LiveTurnSnapshot?, stream: AsyncStream<ChatEvent>) {
        await session.subscribe()
    }

    public func cancel() async {
        await session.cancel()
    }

    public func confirmToolCall(id: String) async {
        await session.confirmToolCall(id: id)
    }

    public func skipToolCall(id: String) async {
        await session.skipToolCall(id: id)
    }
}
