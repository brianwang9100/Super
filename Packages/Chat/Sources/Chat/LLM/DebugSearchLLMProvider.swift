#if DEBUG
import Core
import Foundation

/// Development-only `LLMProvider` that emits a canned `bible.search` tool call
/// using the user's turn as the query, so the content-search pipeline — tool
/// execution, FTS lookup, result write-back — is exercisable end-to-end with no
/// API key, network, or on-device model.
///
/// Unlike `DebugReadLLMProvider` there is no reference to parse: search is
/// free-text, so the whole last user message becomes the `query` (a canned
/// fallback when it's empty). The `translation` argument is omitted, so the
/// search runs against the user's currently selected translation — the same
/// default the tool's prompt steers real models toward.
///
/// Selected via a seeded `kind == .debug` row whose `modelId` is `Self.modelID`;
/// the file is gated on `#if DEBUG` and compiles out of Release entirely.
/// References the tool by its name string (no `Bible` import), matching the
/// other debug Bible providers.
public struct DebugSearchLLMProvider: LLMProvider {
    public let id: String
    public let displayName: String = "Debug (search)"

    /// Stable model id used by the seeded `ModelConfigurationRecord`, and the
    /// discriminator `makeLLMProvider` switches on within the `.debug` arm.
    public static let modelID = "debug-search"
    public static let modelDisplayName = "Debug search"
    public static let maxContextTokens = 8_192

    /// Bible search tool id, held as a literal so Chat needn't import Bible.
    static let toolName = "bible.search"

    /// Query used when the user's turn has no usable text.
    static let fallbackQuery = "love"

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
                continuation.yield(.messageStart(id: "debug-search-\(UUID().uuidString)", model: model.id))

                // Loop termination: once this turn ran the tool, `ChatSession`
                // re-invokes `stream()` with the tool result as the trailing
                // `.tool` turn. Emit a plain text turn with no tool call so the
                // loop ends. Gate on the *last* message, not "any `.tool` in
                // history", so a fresh user turn still triggers a new search.
                guard messages.last?.role != .tool else {
                    Self.emitDone(into: continuation)
                    continuation.finish()
                    return
                }

                do {
                    // Brief pre-stream pause so the "Waiting" spark is visible.
                    try await Task.sleep(nanoseconds: UInt64.random(in: 150...400) * 1_000_000)
                    let query = Self.query(from: messages)
                    continuation.yield(.contentBlockStart(index: 0, type: .toolUse))
                    continuation.yield(.toolUse(
                        index: 0,
                        id: "debug-tool-\(UUID().uuidString)",
                        name: Self.toolName,
                        input: .object(["query": .string(query)]),
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
        continuation.yield(.textDelta(index: 0, text: "Searched scripture for the requested terms."))
        continuation.yield(.contentBlockStop(index: 0))
        continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    // MARK: - Canned payload

    /// The most recent user turn's text, trimmed, as the search query; the
    /// canned fallback when there is no usable text.
    static func query(from messages: [LLMMessage]) -> String {
        guard let lastUser = messages.last(where: { $0.role == .user }) else { return fallbackQuery }
        let text = lastUser.content
            .compactMap { block -> String? in
                if case .text(let value) = block { return value }
                return nil
            }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallbackQuery : text
    }
}
#endif
