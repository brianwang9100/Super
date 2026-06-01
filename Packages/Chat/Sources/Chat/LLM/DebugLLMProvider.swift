#if DEBUG
import Core
import Foundation

/// Development-only `LLMProvider` that streams canned markdown responses
/// with randomized delays. Lets the UI streaming path (scroll behavior,
/// `MessageList` content-growth, thinking blocks, code-block rendering)
/// be exercised end-to-end without a real LLM endpoint, an API key, or
/// the on-device Apple Foundation Model. Picked up by the host bootstrap
/// when a `ModelConfigurationRecord` with `kind == .debug` exists; that
/// row is auto-seeded on first launch in DEBUG builds and never in
/// Release (the entire file is gated on `#if DEBUG`).
public struct DebugLLMProvider: LLMProvider {
    /// Matches the registering `ModelConfigurationRecord.id` so
    /// `LLMProviderRegistry.setActive(id:)` finds this provider when the
    /// debug row is the selected one. Injected at construction (rather
    /// than hardcoded) so the seeded record id and the registry key are
    /// the same string — the same pattern `AppleFoundationLLMProvider`
    /// follows.
    public let id: String
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
                let messageID = "debug-\(UUID().uuidString)"
                continuation.yield(.messageStart(id: messageID, model: model.id))

                // A user message containing "search" drives the web-search
                // script (`.searchStarted` → text → `.citations`) so the
                // sources pill + citation sink are exercisable in the
                // simulator with no key or network. Mirrors the event shape a
                // real native adapter emits.
                if Self.lastUserText(messages).localizedCaseInsensitiveContains("search") {
                    await Self.streamSearch(into: continuation, messages: messages)
                    continuation.finish()
                    return
                }

                let canned = Self.pickResponse()
                do {
                    // Pre-stream pause so the "Waiting" spark UI is
                    // briefly visible before any delta arrives.
                    try await Self.sleep(milliseconds: Int.random(in: 150...500))

                    // Track block index dynamically so the text block
                    // lands at index 0 when there's no thinking trace —
                    // mirrors the event shape `OpenAICompatibleLLMProvider`
                    // emits and keeps any future index-aware consumer
                    // (multi-block renderers, ordering assertions) happy.
                    var blockIndex = 0
                    if !canned.thinking.isEmpty {
                        continuation.yield(.contentBlockStart(index: blockIndex, type: .thinking))
                        for chunk in Self.tokenChunks(of: canned.thinking) {
                            try Task.checkCancellation()
                            continuation.yield(.thinkingDelta(index: blockIndex, text: chunk))
                            try await Self.sleep(milliseconds: Int.random(in: 20...80))
                        }
                        continuation.yield(.contentBlockStop(index: blockIndex))
                        blockIndex += 1
                    }

                    continuation.yield(.contentBlockStart(index: blockIndex, type: .text))
                    for chunk in Self.tokenChunks(of: canned.text) {
                        try Task.checkCancellation()
                        continuation.yield(.textDelta(index: blockIndex, text: chunk))
                        try await Self.sleep(milliseconds: Int.random(in: 15...60))
                    }
                    continuation.yield(.contentBlockStop(index: blockIndex))

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
        // `randomElement()` only returns `nil` when the bank is empty; the
        // previous `?? responseBank[0]` traded one crash for another. If a
        // developer empties the bank while iterating, surface that
        // explicitly as a debug-visible chat response instead of a trap.
        guard let response = responseBank.randomElement() else {
            return CannedResponse(thinking: "", text: "Debug provider: responseBank is empty.")
        }
        return response
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
        // Verse-citation response — exercises the `BibleReferenceLinkifier`
        // path. Mixes anchors, a same-book continuation after a semicolon,
        // a fresh-book reset after a comma, an inline-code that must not
        // linkify, and a Section 1:2 false-positive that must stay plain
        // text.
        CannedResponse(
            thinking: "Several citations; the linkifier should wrap each.",
            text: """
            A few passages worth holding side-by-side:

            - **Comfort:** Romans 8:28-30 reads as a single thread; the
              same chapter circles back in Romans 8:31-39.
            - **Hope:** Psalm 23 grounds the metaphor; John 3:16-17 is
              its New Testament rhyme.
            - **Love:** 1 Corinthians 13:4-7 is the canonical
              definition; compare 1 John 4:7-8.

            Note that `Genesis 1:1` written inline should *not* tap
            through — that's literal code. Section 1:2 of the appendix
            below is also unrelated.
            """
        ),
    ]

    // MARK: - Web-search script

    /// Canned answer + sources for the search script. The text reads like a
    /// grounded reply so the pill renders under a realistic message.
    private static let searchAnswer = """
    Based on the latest reporting, the rover confirmed subsurface water ice \
    in Jezero crater and relayed fresh imagery this week. Sources below.
    """

    private static let debugCitations: [SourceCitation] = [
        SourceCitation(
            id: "https://www.nasa.gov/mars-rover#0",
            title: "Perseverance confirms subsurface water ice",
            url: URL(string: "https://www.nasa.gov/mars-rover")!
        ),
        SourceCitation(
            id: "https://www.space.com/rover-update#1",
            title: "Mars rover relays new imagery from Jezero crater",
            url: URL(string: "https://www.space.com/rover-update")!
        ),
        SourceCitation(
            id: "https://www.scientificamerican.com/mars#2",
            title: "What the new Mars findings mean for the search for life",
            url: URL(string: "https://www.scientificamerican.com/mars")!
        ),
    ]

    /// Sample Google Search-Suggestions HTML for the "gemini" search trigger,
    /// exercising the always-visible `GeminiSearchSuggestionsView` strip without
    /// a real grounded response. A minimal stand-in for Gemini's
    /// `searchEntryPoint.renderedContent` (the real payload is richer styled
    /// HTML); rendered unmodified by the strip just like the live one.
    private static let debugSuggestionsHTML = """
    <html><head><style>.c{font-family:-apple-system;font-size:14px;\
    display:inline-block;padding:6px 12px;border:1px solid #ddd;\
    border-radius:16px;margin:2px;color:#1a73e8;text-decoration:none}</style></head>\
    <body><a class="c" href="https://www.google.com/search?q=mars+rover+news">mars rover news</a>\
    <a class="c" href="https://www.google.com/search?q=jezero+crater+water">jezero crater water</a></body></html>
    """

    /// Emit the `searchStarted → text → citations → messageComplete` sequence.
    /// When the user text mentions "gemini" it additionally emits
    /// `.searchSuggestionsHTML` so the mandatory Suggestions strip is
    /// exercisable. Errors (cancellation) surface as `.error` then a terminal
    /// `.messageComplete`, matching the real providers' stream contract.
    private static func streamSearch(
        into continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation,
        messages: [LLMMessage]
    ) async {
        let emitsSuggestions = lastUserText(messages).localizedCaseInsensitiveContains("gemini")
        do {
            try await sleep(milliseconds: Int.random(in: 150...500))
            continuation.yield(.searchStarted(query: "latest mars rover news"))
            try await sleep(milliseconds: Int.random(in: 250...600))

            continuation.yield(.contentBlockStart(index: 0, type: .text))
            for chunk in tokenChunks(of: searchAnswer) {
                try Task.checkCancellation()
                continuation.yield(.textDelta(index: 0, text: chunk))
                try await sleep(milliseconds: Int.random(in: 15...60))
            }
            continuation.yield(.contentBlockStop(index: 0))

            continuation.yield(.citations(debugCitations))
            if emitsSuggestions {
                continuation.yield(.searchSuggestionsHTML(debugSuggestionsHTML))
            }
            continuation.yield(.messageComplete(usage: TokenUsage(
                inputTokens: messages.reduce(0) { $0 + approxTokens(of: $1) },
                outputTokens: searchAnswer.count / 4
            )))
        } catch is CancellationError {
            continuation.yield(.error(.cancelled))
            continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
        } catch {
            continuation.yield(.error(.requestFailed(error.localizedDescription)))
            continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
        }
    }

    /// The most recent user message's flattened text, used for trigger
    /// detection. Empty when there is no user turn.
    private static func lastUserText(_ messages: [LLMMessage]) -> String {
        guard let last = messages.last(where: { $0.role == .user }) else { return "" }
        return last.content.compactMap { block in
            if case .text(let value) = block { return value }
            return nil
        }.joined(separator: " ")
    }

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
            case .toolUse, .toolResult, .searchResult:
                return acc + 8
            }
        }
    }
}
#endif
