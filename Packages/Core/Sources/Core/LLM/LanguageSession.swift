import FoundationModels
import Foundation

/// Test seam: the final framework session would run a real on-device model.
protocol LanguageSession: Sendable {
    /// Cumulative text snapshots with prior content as a prefix. Tools execute in-band
        /// and never appear as separate stream events.
    func streamResponse(
        to prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, any Error>
}

/// One session per turn, with transcript history and in-band tools.
typealias LanguageSessionFactory = @Sendable (
    _ transcript: Transcript,
    _ tools: [any FoundationModels.Tool]
) -> any LanguageSession

/// Outer stream termination cancels the bridging task.
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
