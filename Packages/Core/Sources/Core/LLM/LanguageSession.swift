import FoundationModels
import Foundation

/// Test seam over `FoundationModels.LanguageModelSession`. The framework
/// type is `final class` — no protocol, no public subclass hook — so
/// `AppleFoundationLLMProvider` can't be unit-tested against the real
/// session: the model would actually run, requiring Apple Intelligence
/// to be enabled on the host. The protocol below exposes the minimum
/// surface the provider uses; `LiveLanguageSession` wraps the real
/// session for production, and the suite injects a scripted fake.
///
/// Phase 3 surface is text-only. Phase 4 will expand the factory closure
/// to accept the tool list once the dynamic-tool adapter lands.
protocol LanguageSession: Sendable {
    /// Yield the model's cumulative text snapshot every time it emits.
    /// Each snapshot starts with the previous one's content; the provider
    /// diffs successive snapshots into `LLMStreamEvent.textDelta` events.
    func streamResponse(
        to prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, any Error>
}

/// Factory the provider uses to spawn one session per turn. Captures the
/// translated transcript built from the orchestrator's `[LLMMessage]`.
typealias LanguageSessionFactory = @Sendable (_ transcript: Transcript) -> any LanguageSession

/// Production conformer that wraps a real `LanguageModelSession`. Bridges
/// its `ResponseStream<String>` (cumulative `Snapshot.content`) into an
/// `AsyncThrowingStream<String, any Error>` so the provider sees the same
/// shape every conformer produces. Cancellation of the outer stream
/// propagates via the bridging `Task`'s `onTermination`.
struct LiveLanguageSession: LanguageSession {
    private let session: LanguageModelSession

    init(session: LanguageModelSession) {
        self.session = session
    }

    func streamResponse(
        to prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
