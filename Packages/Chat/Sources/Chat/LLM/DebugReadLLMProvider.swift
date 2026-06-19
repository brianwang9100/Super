#if DEBUG
import Core
import Foundation

/// Development-only `LLMProvider` that emits a canned `bible.lookup` tool call
/// with `action:'read'` from the scripture reference in the user's turn, so the
/// lookup pipeline — tool execution, verse load, result write-back — is
/// exercisable end-to-end with no API key, network, or on-device model.
///
/// Parses standard notation ("John 3:16-17", "Psalm 23", "Romans") out of the
/// turn via `DebugBibleTarget.parse`, then maps it onto `bible.lookup`'s read
/// parameters: a verse reference reads that range, a chapter reference reads
/// the whole chapter, and a bare book reads its first chapter (the tool
/// requires a chapter). The `translation` argument is omitted, so the read uses
/// the user's currently selected translation — the same default the tool's
/// prompt steers real models toward.
///
/// Selected via a seeded `kind == .debug` row whose `modelId` is `Self.modelID`;
/// the file is gated on `#if DEBUG` and compiles out of Release entirely.
/// References the tool by its name string (no `Bible` import), matching the
/// other debug Bible providers.
public struct DebugReadLLMProvider: LLMProvider {
    public let id: String
    public let displayName: String = "Debug (read)"

    /// Stable model id used by the seeded `ModelConfigurationRecord`, and the
    /// discriminator `makeLLMProvider` switches on within the `.debug` arm.
    public static let modelID = "debug-read"
    public static let modelDisplayName = "Debug read"
    public static let maxContextTokens = 8_192

    /// Bible lookup tool id, held as a literal so Chat needn't import Bible.
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
                    // Brief pre-stream pause so the "Waiting" spark is visible.
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

    /// Build the `bible.lookup` `JSONValue` input for `target`, matching the
    /// tool's read-action schema: `action:'read'` plus a single-element
    /// `references` array. A `book` target carries no chapter, so it defaults to
    /// chapter 1 (the tool requires one); verse bounds are passed only when the
    /// reference named them. `translation` is omitted, so the read uses the
    /// user's currently selected translation.
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
