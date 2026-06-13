import Core
import Foundation

/// Stateful reducer turning Gemini's `streamGenerateContent` chunk sequence
/// into the normalized `LLMStreamEvent` stream every Super UI consumer expects,
/// including the native web-search cases (`.searchStarted`, `.citations`, and
/// the Gemini-only `.searchSuggestionsHTML`).
///
/// Same ownership/policy as the other native reducers
/// (`OpenAIResponsesStreamReducer`, `AnthropicStreamReducer`): a struct that
/// owns the sequencing state for one in-flight response and is driven purely by
/// `consume(_:)` + `finish()`. Neither method throws — a malformed shape
/// surfaces as an `.error(...)` event in the returned array.
///
/// Gemini differs from the block-indexed providers: a chunk's `parts` carry
/// prose fragments inline (a `thought:true` part is reasoning, a plain `text`
/// part is the answer), so this reducer tracks a *single* open prose block and
/// switches it — closing one and opening the next — when the part kind flips
/// between thinking and text. Function calls are delivered whole (not streamed)
/// and bracket their own start/stop. Native search lands in `groundingMetadata`
/// on (typically) the final chunk: `webSearchQueries` → `.searchStarted`,
/// `groundingChunks`+`groundingSupports` → `.citations`, and
/// `searchEntryPoint.renderedContent` → `.searchSuggestionsHTML`. There is no
/// terminal SSE (Server-Sent Events) event — the stream ends when the
/// connection closes, so `finish()` is the sole driver of the final
/// `.messageComplete`.
struct GeminiStreamReducer {
    private var emittedMessageStart = false
    private var capturedID: String?
    private var capturedModel: String?
    private var inputTokens = 0
    private var outputTokens = 0
    /// Implicit-cache hit count from `usageMetadata`. `nil` until a chunk
    /// reports one, so a cache-free stream leaves the field `nil`.
    private var cachedContentTokenCount: Int?
    private var emittedComplete = false
    private var hadError = false

    /// Monotonic normalized content-block index.
    private var nextBlockIndex = 0

    /// The most recent `thoughtSignature` seen on any part this turn. Gemini's
    /// thinking models may deliver the signature on a *separate* (often
    /// empty-text) part that precedes the `functionCall` rather than on the
    /// call part itself; the follow-up turn is rejected with HTTP 400 if it's
    /// dropped, so we hold the last one seen and attach it to the next tool
    /// call. See https://ai.google.dev/gemini-api/docs/thought-signatures.
    private var pendingThoughtSignature: String?

    /// The single open prose block, if any. Gemini interleaves thinking and
    /// text as parts, so the reducer closes/reopens this when the kind flips.
    private enum ProseBlock {
        case text(index: Int)
        case thinking(index: Int)
    }
    private var openProse: ProseBlock?

    /// Each native-search signal is emitted at most once per turn — Gemini
    /// usually delivers all of `groundingMetadata` in the final chunk, but a
    /// model could split it; the flags keep a duplicate chunk from re-firing.
    private var emittedSearchStarted = false
    private var emittedCitations = false
    private var emittedSuggestionsHTML = false

    /// Per-citation ordinal so each `SourceCitation.id` is unique even when two
    /// grounding chunks point at the same URL (deduped on URL later by
    /// `ChatSession`).
    private var citationOrdinal = 0

    /// Process one decoded Gemini chunk and return the normalized events it
    /// produced, in observation order.
    mutating func consume(_ chunk: GeminiStreamResponse) -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []

        // A streamed error envelope ends the turn. Honor the messageStart-first
        // contract, close any open block before the error, and suppress
        // anything that follows.
        if let error = chunk.error {
            ensureMessageStart(into: &events)
            events.append(contentsOf: closeOpenBlocks())
            hadError = true
            events.append(.error(.providerError(
                code: error.status ?? error.code.map(String.init) ?? "error",
                message: error.message ?? "Gemini stream error"
            )))
            return events
        }

        if hadError { return events }

        if let model = chunk.modelVersion { capturedModel = model }
        if let id = chunk.responseId { capturedID = id }
        if let usage = chunk.usageMetadata {
            if let prompt = usage.promptTokenCount { inputTokens = prompt }
            if let candidates = usage.candidatesTokenCount { outputTokens = candidates }
            // Last-wins is correct for Gemini (unlike Anthropic's latch):
            // usageMetadata appears only on the final chunk, so there's no
            // earlier value to protect.
            if let cached = usage.cachedContentTokenCount { cachedContentTokenCount = cached }
        }

        // Every turn opens with `.messageStart` before any content.
        ensureMessageStart(into: &events)

        guard let candidate = chunk.candidates?.first else { return events }

        for part in candidate.content?.parts ?? [] {
            applyPart(part, into: &events)
        }

        if let grounding = candidate.groundingMetadata {
            applyGrounding(grounding, into: &events)
        }

        return events
    }

    /// Final-flush hook. Closes the open prose block and emits the terminal
    /// `.messageComplete(usage:)`. Idempotent.
    mutating func finish() -> [LLMStreamEvent] {
        closeOut()
    }

    /// Flush the deferred `.messageStart` if it hasn't been emitted, and
    /// nothing else (the provider's thrown-error path calls this so an early
    /// transport/encoding failure still honors the messageStart-first contract).
    mutating func flushPendingStart() -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []
        ensureMessageStart(into: &events)
        return events
    }

    /// Whether an `.error` has already surfaced — the provider reads this in
    /// its catch path to avoid double-reporting a transport error over a more
    /// specific streamed one.
    var hasErrored: Bool { hadError }

    /// Record that the provider already surfaced an error (its thrown-error
    /// catch path). Suppresses further block flushing.
    mutating func markErrored() {
        hadError = true
    }

    // MARK: - Parts

    private mutating func applyPart(
        _ part: GeminiStreamResponse.Part,
        into events: inout [LLMStreamEvent]
    ) {
        // A `thoughtSignature` can ride this part — including a content-free
        // part whose only payload is the signature — so capture it before any
        // early return below drops the part. The next tool call replays it.
        if let signature = part.thoughtSignature, !signature.isEmpty {
            pendingThoughtSignature = signature
        }

        // A function call is delivered whole and brackets its own block.
        if let call = part.functionCall, let name = call.name, !name.isEmpty {
            closeProse(into: &events)
            let index = allocateBlockIndex()
            events.append(.contentBlockStart(index: index, type: .toolUse))
            // Use Gemini's per-call id as the call identity; it round-trips on
            // the next turn's functionResponse so results match calls (see
            // translate(_:)). Older/id-less turns fall back to the function name
            // — fine for a single call, but two same-name calls would collide,
            // which is why newer models supply the id. Replay the thinking
            // model's signature (from this part or the most recent one seen) on
            // the next turn's functionCall, else Gemini 400s.
            events.append(.toolUse(
                index: index,
                id: call.id ?? name,
                name: name,
                input: call.args ?? .object([:]),
                signature: part.thoughtSignature ?? pendingThoughtSignature
            ))
            // Consume the pending signature so a *second* tool call in the same
            // turn doesn't inherit the first's — parallel calls each carry (or
            // omit) their own.
            pendingThoughtSignature = nil
            events.append(.contentBlockStop(index: index))
            return
        }

        guard let text = part.text, !text.isEmpty else { return }
        if part.thought == true {
            let index = ensureProse(.thinking, into: &events)
            events.append(.thinkingDelta(index: index, text: text))
        } else {
            let index = ensureProse(.text, into: &events)
            events.append(.textDelta(index: index, text: text))
        }
    }

    /// Kind discriminator for `ensureProse` (the associated index lives on the
    /// `ProseBlock` state, not here).
    private enum ProseKind { case text, thinking }

    /// Ensure the open prose block matches `kind`, switching (close + open) when
    /// it doesn't. Returns the normalized index to attach the delta to.
    private mutating func ensureProse(_ kind: ProseKind, into events: inout [LLMStreamEvent]) -> Int {
        switch (openProse, kind) {
        case (.text(let index), .text), (.thinking(let index), .thinking):
            return index
        default:
            closeProse(into: &events)
            let index = allocateBlockIndex()
            switch kind {
            case .text:
                openProse = .text(index: index)
                events.append(.contentBlockStart(index: index, type: .text))
            case .thinking:
                openProse = .thinking(index: index)
                events.append(.contentBlockStart(index: index, type: .thinking))
            }
            return index
        }
    }

    private mutating func closeProse(into events: inout [LLMStreamEvent]) {
        switch openProse {
        case .text(let index), .thinking(let index):
            events.append(.contentBlockStop(index: index))
        case .none:
            break
        }
        openProse = nil
    }

    // MARK: - Grounding

    /// Emit the native-search signals for a chunk's grounding. These are
    /// side-channel events (`ChatSession` accumulates them independently of the
    /// content blocks), so — unlike a block switch — they deliberately do *not*
    /// close the open prose block first. Gemini delivers grounding in the final
    /// chunk, so in practice `.searchStarted`/`.citations` land *after* the
    /// answer text (vs. Anthropic, whose server-tool call precedes the text);
    /// the answer is already complete by then, so ordering is cosmetic.
    private mutating func applyGrounding(
        _ grounding: GeminiStreamResponse.GroundingMetadata,
        into events: inout [LLMStreamEvent]
    ) {
        if !emittedSearchStarted, let queries = grounding.webSearchQueries, !queries.isEmpty {
            events.append(.searchStarted(query: queries.joined(separator: ", ")))
            emittedSearchStarted = true
        }

        if !emittedCitations, let chunks = grounding.groundingChunks, !chunks.isEmpty {
            let citations = buildCitations(chunks: chunks, supports: grounding.groundingSupports ?? [])
            if !citations.isEmpty {
                events.append(.citations(citations))
                emittedCitations = true
            }
        }

        if !emittedSuggestionsHTML,
           let html = grounding.searchEntryPoint?.renderedContent,
           !html.isEmpty {
            events.append(.searchSuggestionsHTML(html))
            emittedSuggestionsHTML = true
        }
    }

    /// Map grounding chunks to `SourceCitation`s, attaching the first matching
    /// support segment's text as the snippet. Skips chunks whose URL is missing
    /// or malformed (per-citation tolerance, like the other reducers).
    private mutating func buildCitations(
        chunks: [GeminiStreamResponse.GroundingChunk],
        supports: [GeminiStreamResponse.GroundingSupport]
    ) -> [SourceCitation] {
        var citations: [SourceCitation] = []
        for (index, chunk) in chunks.enumerated() {
            guard let uri = chunk.web?.uri, let url = URL(string: uri) else { continue }
            let snippet = supports.first { $0.groundingChunkIndices?.contains(index) == true }?.segment?.text
            let ordinal = citationOrdinal
            citationOrdinal += 1
            citations.append(SourceCitation(
                id: "\(url.absoluteString)#\(ordinal)",
                title: chunk.web?.title ?? "",
                url: url,
                snippet: snippet
            ))
        }
        return citations
    }

    // MARK: - Lifecycle

    private mutating func allocateBlockIndex() -> Int {
        let index = nextBlockIndex
        nextBlockIndex += 1
        return index
    }

    /// Close the open prose block (if any) by emitting its `.contentBlockStop`.
    /// Idempotent: clears `openProse`. Used by both `closeOut()` and the error
    /// path so `.error` lands immediately before the terminal `.messageComplete`.
    mutating func closeOpenBlocks() -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []
        closeProse(into: &events)
        return events
    }

    /// Emit close events + `.messageComplete` exactly once.
    private mutating func closeOut() -> [LLMStreamEvent] {
        if emittedComplete { return [] }
        var events: [LLMStreamEvent] = []
        ensureMessageStart(into: &events)
        events.append(contentsOf: closeOpenBlocks())
        events.append(.messageComplete(usage: TokenUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadInputTokens: cachedContentTokenCount
        )))
        emittedComplete = true
        return events
    }

    private mutating func ensureMessageStart(into events: inout [LLMStreamEvent]) {
        guard !emittedMessageStart else { return }
        events.append(.messageStart(id: capturedID ?? "", model: capturedModel ?? ""))
        emittedMessageStart = true
    }
}
