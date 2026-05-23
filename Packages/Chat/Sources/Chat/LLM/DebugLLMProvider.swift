#if DEBUG
import Core
import Foundation

/// Development-only `LLMProvider` that streams canned markdown responses
/// with randomized delays. Lets the UI streaming path (scroll behavior,
/// `MessageList` content-growth, thinking blocks, code-block rendering)
/// be exercised end-to-end without a real LLM endpoint, an API key, or
/// the on-device Apple Foundation Model. Picked up by `AppBootstrap`
/// when a `ModelConfigurationRecord` with `kind == .debug` exists; that
/// row is auto-seeded on first launch in DEBUG builds and never in
/// Release (the entire file is gated on `#if DEBUG`).
public struct DebugLLMProvider: LLMProvider {
    public let id: String = "debug"
    public let displayName: String = "Debug (canned responses)"

    /// Stable model id used by the seeded `ModelConfigurationRecord`.
    public static let modelID = "debug-default"
    public static let modelDisplayName = "Debug stream"
    public static let maxContextTokens = 8_192

    public var supportedModels: [LLMModel] {
        [LLMModel(
            id: Self.modelID,
            displayName: Self.modelDisplayName,
            supportsThinking: true,
            supportsTools: false,
            maxContextTokens: Self.maxContextTokens
        )]
    }

    public init() {}

    public func stream(
        messages: [LLMMessage],
        model: LLMModel,
        tools: [LLMTool],
        temperature: Double
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let messageID = "debug-\(UUID().uuidString)"
                continuation.yield(.messageStart(id: messageID, model: model.id))

                let canned = Self.pickResponse()
                do {
                    // Pre-stream pause so the "Waiting" spark UI is
                    // briefly visible before any delta arrives.
                    try await Self.sleep(milliseconds: Int.random(in: 150...500))

                    if !canned.thinking.isEmpty {
                        continuation.yield(.contentBlockStart(index: 0, type: .thinking))
                        for chunk in Self.tokenChunks(of: canned.thinking) {
                            try Task.checkCancellation()
                            continuation.yield(.thinkingDelta(index: 0, text: chunk))
                            try await Self.sleep(milliseconds: Int.random(in: 20...80))
                        }
                        continuation.yield(.contentBlockStop(index: 0))
                    }

                    continuation.yield(.contentBlockStart(index: 1, type: .text))
                    for chunk in Self.tokenChunks(of: canned.text) {
                        try Task.checkCancellation()
                        continuation.yield(.textDelta(index: 1, text: chunk))
                        try await Self.sleep(milliseconds: Int.random(in: 15...60))
                    }
                    continuation.yield(.contentBlockStop(index: 1))

                    continuation.yield(.messageComplete(usage: TokenUsage(
                        inputTokens: messages.reduce(0) { $0 + Self.approxTokens(of: $1) },
                        outputTokens: canned.text.count / 4
                    )))
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

    // MARK: - Response bank

    private struct CannedResponse: Sendable {
        let thinking: String
        let text: String
    }

    private static func pickResponse() -> CannedResponse {
        responseBank.randomElement() ?? responseBank[0]
    }

    private static let responseBank: [CannedResponse] = [
        CannedResponse(
            thinking: "User wants a short reply. Keep it under two sentences.",
            text: "Sure thing — the answer is yes, and the reason is that the underlying invariant always holds."
        ),
        CannedResponse(
            thinking: "",
            text: """
            Here's a quick walk-through with code:

            ```swift
            func fibonacci(_ n: Int) -> Int {
                guard n > 1 else { return n }
                var a = 0, b = 1
                for _ in 2...n {
                    (a, b) = (b, a + b)
                }
                return b
            }
            ```

            That runs in `O(n)` time and `O(1)` space.
            """
        ),
        CannedResponse(
            thinking: "Three-part question — answer each with a heading.",
            text: """
            ## Background

            The system has three layers: the **shell**, the **applets**, and the **event bus**. Each layer has a single owner.

            ## Trade-offs

            - The shell is opinionated, which keeps the applets thin.
            - The event bus is generic, which lets the shell stay applet-agnostic.
            - Applets cannot import each other — cross-applet flow goes through the bus.

            ## Recommendation

            Lean on the event bus for any new cross-applet feature; resist the temptation to add a shortcut import.
            """
        ),
        CannedResponse(
            thinking: "Long-form, with a list and a code block, to stress streaming.",
            text: """
            Great question — there are a few things going on here, so let me unpack them one at a time.

            1. **Layout** — SwiftUI's `LazyVStack` lazily measures off-screen rows. Estimated heights are used until each row gets a chance to lay out.
            2. **Scrolling** — `ScrollPosition` is imperative; `scrollTo(edge:)` resolves once against the current `contentSize`, which may still be a lazy estimate.
            3. **Anchors** — `defaultScrollAnchor(.bottom)` is the declarative alternative. It re-evaluates continuously as `contentSize` changes.

            Here's a minimal example:

            ```swift
            ScrollView {
                LazyVStack {
                    ForEach(messages) { row($0) }
                }
            }
            .defaultScrollAnchor(.bottom)
            ```

            That keeps the bottom anchored across viewport shrinks (keyboard show) and content growth (new messages, streaming deltas).

            Let me know if you want me to dig into any one of these in more depth.
            """
        ),
        CannedResponse(
            thinking: "Short acknowledgement is fine.",
            text: "Got it — running the test now."
        ),
    ]

    // MARK: - Helpers

    /// Split `text` into short chunks so the delta stream looks token-ish
    /// (1–8 chars at a time) rather than landing the whole response in
    /// one event. Splits on spaces and emits intra-word slices for long
    /// runs (e.g. URLs) so the cadence stays even.
    private static func tokenChunks(of text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for char in text {
            current.append(char)
            if char == " " || char == "\n" || current.count >= Int.random(in: 3...8) {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func sleep(milliseconds: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }

    private static func approxTokens(of message: LLMMessage) -> Int {
        message.content.reduce(0) { acc, block in
            switch block {
            case .text(let s):
                return acc + s.count / 4
            case .toolUse, .toolResult:
                return acc + 8
            }
        }
    }
}
#endif
