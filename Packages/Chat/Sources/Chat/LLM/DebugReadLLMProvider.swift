#if DEBUG
import Core
import Foundation

public struct DebugReadLLMProvider: LLMProvider {
    public let id: String
    public let displayName: String = "Debug (read)"

    public static let modelID = "debug-read"
    public static let modelDisplayName = "Debug read"
    public static let maxContextTokens = 8_192

    /// Kept as a literal so Chat does not import Bible.
    static let toolName = "bible.lookup"

    public var supportedModels: [LLMModel] {
        [LLMModel(
            id: Self.modelID,
            displayName: Self.modelDisplayName,
            supportsThinking: false,
            supportsTools: true,
            maxContextTokens: Self.maxContextTokens
        )]
    }

    public init(id: String) {
        self.id = id
    }

    public func stream(
        messages: [LLMMessage],
        model: LLMModel,
        tools: [LLMTool],
        temperature: Double
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.messageStart(id: "debug-read-\(UUID().uuidString)", model: model.id))

                // Loop termination: once this turn ran the tool, `ChatSession`
                // re-invokes `stream()` with the tool result as the trailing
                // `.tool` turn. Emit a plain text turn with no tool call so the
                // loop ends — otherwise we'd read forever. Gate on the *last*
                // message, not "any `.tool` in history", so a fresh user turn
                // after an earlier debug-tool run still triggers a new read.
                guard messages.last?.role != .tool else {
                    Self.emitDone(into: continuation)
                    continuation.finish()
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: UInt64.random(in: 150...400) * 1_000_000)
                    let target = DebugBibleTarget.parse(from: messages)
                    continuation.yield(.contentBlockStart(index: 0, type: .toolUse))
                    continuation.yield(.toolUse(
                        index: 0,
                        id: "debug-tool-\(UUID().uuidString)",
                        name: Self.toolName,
                        input: Self.readInput(for: target),
                        signature: nil
                    ))
                    continuation.yield(.contentBlockStop(index: 0))
                    continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
                } catch is CancellationError {
                    continuation.yield(.error(.cancelled))
                    continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
                } catch {
                    continuation.yield(.error(.requestFailed(error.localizedDescription)))
                    continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func emitDone(
        into continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) {
        continuation.yield(.contentBlockStart(index: 0, type: .text))
        continuation.yield(.textDelta(index: 0, text: "Read the requested passage."))
        continuation.yield(.contentBlockStop(index: 0))
        continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    // MARK: - Canned payload

    /// A whole-book target defaults to chapter 1 because the tool requires a chapter.
    static func readInput(for target: DebugBibleTarget) -> JSONValue {
        var reference: [String: JSONValue] = [
            "book": .string(target.bookId),
            "chapter": .int(target.chapterNumber ?? 1),
        ]
        if let verseStart = target.verseStart { reference["startVerse"] = .int(verseStart) }
        if let verseEnd = target.verseEnd { reference["endVerse"] = .int(verseEnd) }
        return .object([
            "action": .string("read"),
            "references": .array([.object(reference)]),
        ])
    }
}
#endif
