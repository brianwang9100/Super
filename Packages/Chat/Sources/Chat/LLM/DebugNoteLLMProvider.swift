#if DEBUG
import Core
import Foundation

/// Development-only `LLMProvider` that emits a canned `bible.note` (`create`)
/// tool call instead of a chat reply, so the Bible note pipeline — tool
/// execution, repository write, reactive `@Query` render — is exercisable
/// end-to-end with no API key, network, or on-device model.
///
/// Note creation is chat-only (there is no headless note dispatcher), so this
/// provider drives one path: select it, send a message naming a target (or
/// not — it falls back to John 3:16), and a fake `.assistant` note lands.
/// Selected via a seeded `kind == .debug` row whose `modelId` is
/// `Self.modelID`; the file is gated on `#if DEBUG` and compiles out of
/// Release entirely. References the tool by its name string (no `Bible`
/// import).
public struct DebugNoteLLMProvider: LLMProvider {
    public let id: String
    public let displayName: String = "Debug (note)"

    /// Stable model id used by the seeded `ModelConfigurationRecord`, and the
    /// discriminator `makeLLMProvider` switches on within the `.debug` arm.
    public static let modelID = "debug-note"
    public static let modelDisplayName = "Debug note"
    public static let maxContextTokens = 8_192

    /// Bible note tool id, held as a literal so Chat needn't import Bible.
    static let toolName = "bible.note"

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
                continuation.yield(.messageStart(id: "debug-note-\(UUID().uuidString)", model: model.id))

                // Loop termination — see DebugAnnotateLLMProvider for the
                // rationale: suppress only when *this* turn just ran the tool
                // (the trailing message is its `.tool` result), not whenever
                // history contains any tool result, so a fresh user turn after
                // an earlier debug-tool call still fires.
                guard messages.last?.role != .tool else {
                    continuation.yield(.contentBlockStart(index: 0, type: .text))
                    continuation.yield(.textDelta(index: 0, text: "Created a debug note."))
                    continuation.yield(.contentBlockStop(index: 0))
                    continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
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
                        input: Self.noteInput(for: target),
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

    // MARK: - Canned payload

    /// Build the `bible.note` `create` `JSONValue` input for `target`,
    /// matching `NoteBibleTool.descriptor`'s parameter schema.
    static func noteInput(for target: DebugBibleTarget) -> JSONValue {
        var fields: [String: JSONValue] = [
            "action": .string("create"),
            "target": .string(target.target),
            "bookId": .string(target.bookId),
            "body": .string("Debug note: a canned assistant note for testing the Bible note pipeline."),
        ]
        if let chapter = target.chapterNumber { fields["chapterNumber"] = .int(chapter) }
        if let verseStart = target.verseStart { fields["verseStart"] = .int(verseStart) }
        if let verseEnd = target.verseEnd { fields["verseEnd"] = .int(verseEnd) }
        return .object(fields)
    }
}
#endif
