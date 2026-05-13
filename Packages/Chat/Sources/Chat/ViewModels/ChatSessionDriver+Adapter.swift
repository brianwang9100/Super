import Core
import Foundation

/// Production conformer that bridges the view model's `ChatSessionDriver`
/// dependency to the underlying actor `ChatSession`. Lives as a separate
/// type rather than a direct conformance because:
///
/// - `ChatSession.send(text:model:temperature:)` carries a default
///   `temperature` argument that doesn't satisfy the protocol's exact
///   signature; threading temperature here lets the view model stay
///   ignorant of provider-specific knobs.
/// - Future drivers (e.g. a deterministic snapshot-test driver, or a
///   Grouped-conversation driver) can conform directly without having to
///   subclass an actor.
public struct LiveChatSessionDriver: ChatSessionDriver {
    private let session: ChatSession
    private let temperature: Double

    public init(session: ChatSession, temperature: Double = 1.0) {
        self.session = session
        self.temperature = temperature
    }

    public func send(text: String, model: LLMModel) async -> AsyncStream<ChatEvent> {
        await session.send(text: text, model: model, temperature: temperature)
    }

    public func subscribe() async -> (snapshot: ChatSession.LiveTurnSnapshot?, stream: AsyncStream<ChatEvent>) {
        await session.subscribe()
    }

    public func cancel() async {
        await session.cancel()
    }
}
