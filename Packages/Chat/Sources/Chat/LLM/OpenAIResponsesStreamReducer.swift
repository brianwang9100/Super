import Core
import Foundation

/// Stateful reducer turning the OpenAI Responses streaming event sequence
/// into the normalized `LLMStreamEvent` stream every Super UI consumer
/// expects, including the native web-search cases (`.searchStarted`,
/// `.citations`).
///
/// Same ownership/policy as `OpenAIStreamReducer`: a struct that owns the
/// sequencing state for one in-flight response (block indices, partial
/// tool-call buffers, captured usage) and is driven purely by `consume(_:)`
/// + `finish()`. Neither method throws — a malformed tool-call argument
/// string surfaces as an `.error(...)` event in the returned array so the
/// caller persists whatever did arrive.
///
/// Terminates on the `response.completed` event (the Responses API has no
/// `[DONE]` sentinel); `finish()` is the safety net for a stream that closes
/// without it.
struct OpenAIResponsesStreamReducer {
    private var emittedMessageStart = false
    private var capturedID: String?
    private var capturedModel: String?
    private var capturedUsage: TokenUsage?
    private var emittedComplete = false

    /// Monotonic content-block index, same role as in `OpenAIStreamReducer`.
    /// The `…Index` suffix keeps the stored state distinct from the
    /// `openTextBlock(into:)` / `openThinkingBlock(into:)` opener methods below.
    private var nextBlockIndex = 0
    private var openTextBlockIndex: Int?
    private var openThinkingBlockIndex: Int?

    /// `.searchStarted` is emitted at most once per turn; the query is
    /// captured from the `web_search_call` item when the API supplies one.
    private var emittedSearchStarted = false
    private var pendingSearchQuery: String?

    /// Set once any `.error` has been emitted (an SSE `response.error`, or the
    /// provider's thrown-error path via `markErrored()`). Suppresses the
    /// tool-call flush in `closeOut()` so a half-streamed `function_call`'s
    /// unparseable arguments don't tack a spurious `.decodingFailed` on *after*
    /// the meaningful transport error — `ChatSession` keeps the last `.error`,
    /// so the decode failure would otherwise mask the real cause.
    private var hadError = false

    /// Per-citation ordinal so each `SourceCitation.id` is unique even when
    /// two annotations point at the same URL within one turn (the persisted
    /// set is later deduped on URL by `ChatSession`).
    private var citationOrdinal = 0

    /// Partial function-call accumulators keyed by the streaming item id.
    /// Arguments arrive as fragmented JSON and are flushed at completion.
    private var toolBuilders: [String: ToolCallBuilder] = [:]
    private var toolOrder: [String] = []

    /// Process one decoded Responses event and return the normalized events
    /// it produced, in the order downstream consumers should observe them.
    mutating func consume(_ event: OpenAIResponsesStreamEvent) -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []

        // Once an error has been surfaced the turn is over: ignore any trailing
        // content/tool events a terminal `response.error` might be followed by,
        // so nothing lands after the error. `response.completed` is still let
        // through so its usage + block-close + `.messageComplete` run.
        if hadError, event.type != "response.completed" {
            return events
        }

        switch event.type {
        case "response.created":
            if let response = event.response {
                if let id = response.id { capturedID = id }
                if let model = response.model { capturedModel = model }
            }

        case "response.output_item.added":
            if let item = event.item {
                switch item.type {
                case "web_search_call":
                    // Emit `.searchStarted` here — and ONLY here — because this
                    // item is the one event that carries the query. The
                    // `in_progress`/`searching` events don't, and emitting on
                    // them would lock in an empty query if they arrived first
                    // (which the API doesn't guarantee against). Emit once, with
                    // the query when present.
                    if let query = item.action?.query, !query.isEmpty {
                        pendingSearchQuery = query
                    }
                    ensureMessageStart(into: &events)
                    emitSearchStartedIfNeeded(into: &events)
                case "function_call":
                    if let id = item.id {
                        toolBuilders[id] = ToolCallBuilder(
                            callID: item.callId ?? id,
                            name: item.name ?? ""
                        )
                        toolOrder.append(id)
                    }
                default:
                    break
                }
            }

        // `response.web_search_call.in_progress` / `.searching` carry no query
        // and no normalized signal of their own — `.searchStarted` already
        // fired from the `web_search_call` item — so they fall through to the
        // default no-op below.

        case "response.output_text.delta":
            if let delta = event.delta, !delta.isEmpty {
                ensureMessageStart(into: &events)
                closeThinkingBlock(into: &events)
                let index = openTextBlock(into: &events)
                events.append(.textDelta(index: index, text: delta))
            }

        case "response.reasoning_summary_text.delta":
            if let delta = event.delta, !delta.isEmpty {
                ensureMessageStart(into: &events)
                let index = openThinkingBlock(into: &events)
                events.append(.thinkingDelta(index: index, text: delta))
            }

        case "response.function_call_arguments.delta":
            if let id = event.itemId, let delta = event.delta {
                toolBuilders[id]?.arguments.append(delta)
            }

        case "response.output_text.annotation.added":
            // NOTE: the Responses API interleaves annotations with text
            // deltas, so `.citations` is emitted while the text block is still
            // open (no `contentBlockStop` yet) — a deliberate divergence from
            // `OpenAIStreamReducer`, which never interleaves events with a live
            // block. Safe because `ChatSession` accumulates citations in a
            // parallel buffer keyed off `.messageComplete`, not block spans.
            if let annotation = event.annotation,
               annotation.type == "url_citation",
               let urlString = annotation.url,
               let url = URL(string: urlString) {
                ensureMessageStart(into: &events)
                let ordinal = citationOrdinal
                citationOrdinal += 1
                // Carry the provider title verbatim (empty when absent); the
                // UI owns the host-fallback so the title isn't double-derived
                // (reducer host → projection host) into a redundant pill row.
                let citation = SourceCitation(
                    id: "\(url.absoluteString)#\(ordinal)",
                    title: annotation.title ?? "",
                    url: url
                )
                events.append(.citations([citation]))
            }

        case "response.completed":
            if let usage = event.response?.usage,
               let input = usage.inputTokens,
               let output = usage.outputTokens {
                capturedUsage = TokenUsage(inputTokens: input, outputTokens: output)
            }
            events.append(contentsOf: closeOut())

        case "response.error", "error":
            // Honor the messageStart-first contract even when the error lands
            // before any content (e.g. an auth/rate-limit rejection from the
            // routing layer before a response object exists), and close any
            // open block *before* the error so the later `closeOut()` doesn't
            // emit `.contentBlockStop` after it — same ordering the catch path
            // guarantees, so `.error` stays immediately before the terminal.
            ensureMessageStart(into: &events)
            closeThinkingBlock(into: &events)
            closeTextBlock(into: &events)
            hadError = true
            events.append(.error(.providerError(
                code: event.code ?? "error",
                message: event.message ?? "OpenAI Responses stream error"
            )))

        default:
            // Many Responses event types (`response.in_progress`,
            // `response.output_text.done`, `response.output_item.done`, …)
            // carry no normalized signal; ignore them.
            break
        }

        return events
    }

    /// Final-flush hook. Closes open blocks, flushes pending tool calls, and
    /// emits the terminal `.messageComplete(usage:)`. Idempotent — a no-op
    /// after `response.completed` already drove the close.
    mutating func finish() -> [LLMStreamEvent] {
        closeOut()
    }

    /// Flush the deferred `.messageStart` if it hasn't been emitted yet, and
    /// nothing else. The provider calls this before yielding a thrown-error
    /// `.error` so an early transport/encoding failure still honors the
    /// messageStart-first contract; `finish()` then just emits the terminal
    /// `.messageComplete`. A no-op once a start has already been emitted.
    mutating func flushPendingStart() -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []
        ensureMessageStart(into: &events)
        return events
    }

    /// Whether an `.error` has already been surfaced (an SSE `response.error`,
    /// or a prior `markErrored()`). The provider reads this in its catch path
    /// to avoid yielding a second, less-specific transport `.error` over the
    /// already-emitted SSE one (`ChatSession` keeps the last `.error`).
    var hasErrored: Bool { hadError }

    /// Record that the provider already surfaced an error (its thrown-error
    /// catch path). Suppresses the tool-call flush in the subsequent
    /// `finish()` so a half-streamed `function_call` can't append a misleading
    /// `.decodingFailed` after the real transport error.
    mutating func markErrored() {
        hadError = true
    }

    /// Close any open text/thinking content block. The provider calls this in
    /// its error catch *before* yielding `.error`, so a mid-stream failure
    /// produces `…, .contentBlockStop, .error, .messageComplete` — keeping
    /// `.error` immediately before the terminal event per the stream contract,
    /// rather than letting `finish()`'s block-close land between them.
    mutating func closeOpenBlocks() -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []
        closeThinkingBlock(into: &events)
        closeTextBlock(into: &events)
        return events
    }

    /// Emit `.searchStarted` once per turn with whatever query is known so
    /// far. Idempotent; both the `web_search_call` item and the
    /// `in_progress`/`searching` events route through here.
    private mutating func emitSearchStartedIfNeeded(into events: inout [LLMStreamEvent]) {
        guard !emittedSearchStarted else { return }
        events.append(.searchStarted(query: pendingSearchQuery ?? ""))
        emittedSearchStarted = true
    }

    /// Emit close events + `.messageComplete` exactly once. Both the
    /// `response.completed` event and the stream-end `finish()` route through
    /// here; the `emittedComplete` guard makes the second call a no-op.
    private mutating func closeOut() -> [LLMStreamEvent] {
        if emittedComplete { return [] }
        var events: [LLMStreamEvent] = []
        ensureMessageStart(into: &events)
        closeThinkingBlock(into: &events)
        closeTextBlock(into: &events)
        events.append(contentsOf: flushToolCalls())
        let usage = capturedUsage ?? TokenUsage(inputTokens: 0, outputTokens: 0)
        events.append(.messageComplete(usage: usage))
        emittedComplete = true
        return events
    }

    private mutating func ensureMessageStart(into events: inout [LLMStreamEvent]) {
        guard !emittedMessageStart else { return }
        events.append(.messageStart(id: capturedID ?? "", model: capturedModel ?? ""))
        emittedMessageStart = true
    }

    private mutating func openTextBlock(into events: inout [LLMStreamEvent]) -> Int {
        if let existing = openTextBlockIndex { return existing }
        let index = nextBlockIndex
        nextBlockIndex += 1
        openTextBlockIndex = index
        events.append(.contentBlockStart(index: index, type: .text))
        return index
    }

    private mutating func openThinkingBlock(into events: inout [LLMStreamEvent]) -> Int {
        if let existing = openThinkingBlockIndex { return existing }
        let index = nextBlockIndex
        nextBlockIndex += 1
        openThinkingBlockIndex = index
        events.append(.contentBlockStart(index: index, type: .thinking))
        return index
    }

    private mutating func closeTextBlock(into events: inout [LLMStreamEvent]) {
        if let text = openTextBlockIndex {
            events.append(.contentBlockStop(index: text))
            openTextBlockIndex = nil
        }
    }

    private mutating func closeThinkingBlock(into events: inout [LLMStreamEvent]) {
        if let thinking = openThinkingBlockIndex {
            events.append(.contentBlockStop(index: thinking))
            openThinkingBlockIndex = nil
        }
    }

    /// Flush accumulated function-call builders in arrival order. Each call
    /// emits its own block (start → toolUse → stop); a malformed argument
    /// string becomes an `.error` in place of that call's triplet while the
    /// rest still flush. The emitted `id` is the API `call_id` so the next
    /// turn's tool result correlates back to it.
    private mutating func flushToolCalls() -> [LLMStreamEvent] {
        guard !toolBuilders.isEmpty else { return [] }
        // After an error, drop partial tool calls silently — their arguments
        // are mid-stream and "fail" to parse, but that decode failure is an
        // artifact of the interrupted stream, not the real cause. Emitting it
        // would overwrite the meaningful error in `ChatSession`.
        if hadError {
            toolBuilders.removeAll()
            toolOrder.removeAll()
            return []
        }
        var events: [LLMStreamEvent] = []
        for itemID in toolOrder {
            guard let builder = toolBuilders[itemID], !builder.name.isEmpty else { continue }
            do {
                let input = try builder.parsedArguments()
                let blockIndex = nextBlockIndex
                nextBlockIndex += 1
                events.append(.contentBlockStart(index: blockIndex, type: .toolUse))
                events.append(.toolUse(index: blockIndex, id: builder.callID, name: builder.name, input: input))
                events.append(.contentBlockStop(index: blockIndex))
            } catch let error as LLMError {
                events.append(.error(error))
            } catch {
                events.append(.error(.decodingFailed(error.localizedDescription)))
            }
        }
        toolBuilders.removeAll()
        toolOrder.removeAll()
        return events
    }
}

/// Per-function-call accumulator. The Responses API streams `arguments` as a
/// sequence of JSON-string fragments; they're glued back together and parsed
/// once at flush time.
private struct ToolCallBuilder {
    let callID: String
    let name: String
    var arguments: String = ""

    /// Parse the joined arguments string. Empty arguments map to
    /// `.object([:])` so the caller always receives a usable shape.
    func parsedArguments() throws -> JSONValue {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .object([:]) }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
        } catch {
            throw LLMError.decodingFailed("tool call arguments: \(error.localizedDescription)")
        }
    }
}
