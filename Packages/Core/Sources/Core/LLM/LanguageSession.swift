import FoundationModels
import Foundation

/// Test seam over `FoundationModels.LanguageModelSession`. The framework
/// type is `final class` — no protocol, no public subclass hook — so
/// `AppleFoundationLLMProvider` can't be unit-tested against the real
/// session: the model would actually run, requiring Apple Intelligence
/// to be enabled on the host. The protocol below exposes the minimum
/// surface the provider uses; `LiveLanguageSession` wraps the real
/// session for production, and the suite injects a scripted fake.
protocol LanguageSession: Sendable {
    /// Yield the model's cumulative text snapshot every time it emits.
    /// Each snapshot starts with the previous one's content; the provider
    /// diffs successive snapshots into `LLMStreamEvent.textDelta` events.
    /// Tools handed to the session via the factory are invoked in-band
    /// by Apple Foundation Models (AFM) during this stream and never
    /// surface as separate stream events.
    func streamResponse(
        to prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, any Error>
}

/// Factory the provider uses to spawn one session per turn. The
/// `transcript` carries the conversation history; `tools` carries the
/// `DynamicLLMTool` wrappers AFM may invoke during the stream.
typealias LanguageSessionFactory = @Sendable (
    _ transcript: Transcript,
    _ tools: [any FoundationModels.Tool]
) -> any LanguageSession

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

/// Defensive session for an unsupported API path; it never constructs a model
/// and reports the same error contract if a caller gets past the status guard.
struct UnavailableLanguageSession: LanguageSession {
    let error: LLMError

    func streamResponse(to prompt: String, options: GenerationOptions) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
}
