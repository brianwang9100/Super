import Core
import Foundation

/// Stateful reducer turning the Anthropic Messages streaming event sequence
/// into the normalized `LLMStreamEvent` stream every Super UI consumer expects,
/// including the native web-search cases (`.searchStarted`, `.citations`).
///
/// Same ownership/policy as `OpenAIStreamReducer` / `OpenAIResponsesStreamReducer`:
/// a struct that owns the sequencing state for one in-flight response (block
/// index mapping, partial tool-call buffers, captured usage, stashed search
/// results) and is driven purely by `consume(_:)` + `finish()`. Neither method
/// throws — a malformed tool-call argument string surfaces as an `.error(...)`
/// event in the returned array. (`ChatSession` treats a surfaced `.error` as a
/// failed turn and discards the partial buffers rather than persisting them —
/// the events exist so the UI can render what streamed before the failure.)
///
/// Anthropic assigns its own monotonic block indices; this reducer maps each to
/// its own normalized index space, because `server_tool_use` and
/// `web_search_tool_result` blocks produce *no* normalized content block (they
/// drive `.searchStarted` / `.citations` instead), so the wire indices would
/// otherwise leave gaps. Terminates on `message_stop`; `finish()` is the safety
/// net for a stream that closes without it.
struct AnthropicStreamReducer {
    private var emittedMessageStart = false
    private var capturedID: String?
    private var capturedModel: String?
    private var inputTokens = 0
    private var outputTokens = 0
    /// Cache token counts from the `message_start` usage (Anthropic reports them
    /// there, outside `inputTokens`). `nil` until seen, so a stream that never
    /// reports cache activity leaves the `TokenUsage` cache fields `nil` rather
    /// than a misleading 0.
    private var cacheCreationInputTokens: Int?
    private var cacheReadInputTokens: Int?
    private var emittedComplete = false

    /// Set once any `.error` has surfaced (an SSE `error` event, or the
    /// provider's thrown-error path via `markErrored()`). Suppresses all
    /// further content events so nothing lands after the error — `ChatSession`
    /// keeps the last `.error`, so trailing decode noise would mask the real
    /// cause.
    private var hadError = false

    /// Monotonic *normalized* content-block index. Distinct from Anthropic's
    /// wire index (see type doc).
    private var nextBlockIndex = 0

    /// `.searchStarted` is emitted at most once per turn.
    private var emittedSearchStarted = false

    /// Per-citation ordinal so each `SourceCitation.id` is unique even when two
    /// citations point at the same URL within one turn (the persisted set is
    /// later deduped on URL by `ChatSession`).
    private var citationOrdinal = 0

    /// Set when a `redacted_thinking` block opens. A turn containing one is
    /// not replayable from our persistence model (we cannot round-trip the
    /// opaque payload), so the signature emission is suppressed for the
    /// whole turn and the request gate falls back to thinking-off on the
    /// follow-up.
    private var sawRedactedThinking = false

    /// Signature accumulated by the turn's thinking block, stashed at its
    /// clean `content_block_stop` and emitted once at close-out (so a
    /// `redacted_thinking` block arriving in either order still suppresses
    /// it). A stream cut off before the stop never stashes — a partial
    /// signature is unusable.
    private var pendingThinkingSignature: (index: Int, signature: String)?

    /// `web_search_result.encrypted_content` stashed by result URL when the
    /// `web_search_tool_result` block arrives, then attached to each citation's
    /// `providerEcho` when the matching `citations_delta` references that URL.
    /// The encrypted blob MUST round-trip verbatim for the citation to stay
    /// valid on later turns.
    private var encryptedContentByURL: [String: String] = [:]

    /// In-flight block state keyed by Anthropic's wire index.
    private enum OpenBlock {
        case text(normalizedIndex: Int)
        case thinking(normalizedIndex: Int, signature: String)
        case toolUse(normalizedIndex: Int, callID: String, name: String, arguments: String)
        /// The `web_search` server call; accumulates its query JSON until stop.
        case serverToolUse(arguments: String)
        /// A `web_search_tool_result` block; results already stashed at start.
        case webSearchResult
    }
    private var blocks: [Int: OpenBlock] = [:]

    /// Process one decoded Messages event and return the normalized events it
    /// produced, in the order downstream consumers should observe them.
    mutating func consume(_ event: AnthropicStreamEvent) -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []

        // Once an error has surfaced the turn is over: ignore trailing content,
        // but let `message_stop` through so its block-close + `.messageComplete`
        // still run.
        if hadError, event.type != "message_stop" {
            return events
        }

        switch event.type {
        case "message_start":
            if let message = event.message {
                if let id = message.id { capturedID = id }
                if let model = message.model { capturedModel = model }
                if let input = message.usage?.inputTokens { inputTokens = input }
                captureCacheTokens(from: message.usage)
            }
            // We have id/model now, so emit the start immediately (unlike the
            // Responses reducer, which defers until it learns them).
            ensureMessageStart(into: &events)

        case "content_block_start":
            guard let index = event.index, let block = event.contentBlock else { break }
            openBlock(index: index, block: block, into: &events)

        case "content_block_delta":
            guard let index = event.index, let delta = event.delta else { break }
            applyDelta(index: index, delta: delta, into: &events)

        case "content_block_stop":
            guard let index = event.index else { break }
            closeBlock(index: index, into: &events)

        case "message_delta":
            if let output = event.usage?.outputTokens { outputTokens = output }
            // Anthropic carries cache counts on `message_start`, but read them
            // here too in case a future build also reports them on the delta.
            captureCacheTokens(from: event.usage)

        case "message_stop":
            events.append(contentsOf: closeOut())

        case "error":
            // Honor the messageStart-first contract even when the error lands
            // before any content, and close open blocks *before* the error so a
            // later close can't emit `.contentBlockStop` after it — same
            // ordering the catch path guarantees.
            ensureMessageStart(into: &events)
            events.append(contentsOf: closeOpenBlocks())
            hadError = true
            events.append(.error(.providerError(
                code: event.error?.type ?? "error",
                message: event.error?.message ?? "Anthropic stream error"
            )))

        default:
            // `ping` and any unmodeled event types carry no normalized signal.
            break
        }

        return events
    }

    /// Final-flush hook. Closes open blocks and emits the terminal
    /// `.messageComplete(usage:)`. Idempotent — a no-op after `message_stop`
    /// already drove the close.
    mutating func finish() -> [LLMStreamEvent] {
        closeOut()
    }

    /// Flush the deferred `.messageStart` if it hasn't been emitted, and
    /// nothing else. The provider calls this before yielding a thrown-error
    /// `.error` so an early transport/encoding failure still honors the
    /// messageStart-first contract.
    mutating func flushPendingStart() -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []
        ensureMessageStart(into: &events)
        return events
    }

    /// Whether an `.error` has already surfaced. The provider reads this in its
    /// catch path to avoid yielding a second, less-specific transport `.error`
    /// over an already-emitted SSE one.
    var hasErrored: Bool { hadError }

    /// Record that the provider already surfaced an error (its thrown-error
    /// catch path). Suppresses any further block flushing.
    mutating func markErrored() {
        hadError = true
    }

    // MARK: - Block lifecycle

    private mutating func openBlock(
        index: Int,
        block: AnthropicStreamEvent.ContentBlock,
        into events: inout [LLMStreamEvent]
    ) {
        switch block.type {
        case "text":
            ensureMessageStart(into: &events)
            let normalized = allocateBlockIndex()
            blocks[index] = .text(normalizedIndex: normalized)
            events.append(.contentBlockStart(index: normalized, type: .text))
        case "thinking":
            ensureMessageStart(into: &events)
            let normalized = allocateBlockIndex()
            blocks[index] = .thinking(normalizedIndex: normalized, signature: "")
            events.append(.contentBlockStart(index: normalized, type: .thinking))
        case "redacted_thinking":
            // Carries no displayable content (no normalized block), but
            // poisons replayability for the turn — see `sawRedactedThinking`.
            sawRedactedThinking = true
        case "tool_use":
            ensureMessageStart(into: &events)
            let normalized = allocateBlockIndex()
            blocks[index] = .toolUse(
                normalizedIndex: normalized,
                callID: block.id ?? "",
                name: block.name ?? "",
                arguments: ""
            )
            events.append(.contentBlockStart(index: normalized, type: .toolUse))
        case "server_tool_use":
            // The `web_search` call. Query streams as `input_json_delta`; emit
            // `.searchStarted` at block stop where the query is complete.
            ensureMessageStart(into: &events)
            blocks[index] = .serverToolUse(arguments: "")
        case "web_search_tool_result":
            blocks[index] = .webSearchResult
            for result in block.content ?? [] {
                if let url = result.url, let encrypted = result.encryptedContent {
                    encryptedContentByURL[url] = encrypted
                }
            }
        default:
            break
        }
    }

    private mutating func applyDelta(
        index: Int,
        delta: AnthropicStreamEvent.Delta,
        into events: inout [LLMStreamEvent]
    ) {
        switch delta.type {
        case "text_delta":
            if case .text(let normalized) = blocks[index], let text = delta.text, !text.isEmpty {
                events.append(.textDelta(index: normalized, text: text))
            }
        case "thinking_delta":
            if case .thinking(let normalized, _) = blocks[index],
               let thinking = delta.thinking, !thinking.isEmpty {
                events.append(.thinkingDelta(index: normalized, text: thinking))
            }
        case "input_json_delta":
            guard let fragment = delta.partialJson else { break }
            switch blocks[index] {
            case .toolUse(let normalized, let callID, let name, let arguments):
                blocks[index] = .toolUse(
                    normalizedIndex: normalized,
                    callID: callID,
                    name: name,
                    arguments: arguments + fragment
                )
            case .serverToolUse(let arguments):
                blocks[index] = .serverToolUse(arguments: arguments + fragment)
            default:
                break
            }
        case "citations_delta":
            if let citation = delta.citation {
                appendCitation(citation, into: &events)
            }
        case "signature_delta":
            if case .thinking(let normalized, let signature) = blocks[index],
               let fragment = delta.signature, !fragment.isEmpty {
                blocks[index] = .thinking(
                    normalizedIndex: normalized,
                    signature: signature + fragment
                )
            }
        default:
            // Other delta types carry no normalized signal.
            break
        }
    }

    private mutating func closeBlock(index: Int, into events: inout [LLMStreamEvent]) {
        switch blocks[index] {
        case .text(let normalized):
            events.append(.contentBlockStop(index: normalized))
        case .thinking(let normalized, let signature):
            // Last-stash-wins. Safe because we never send the interleaved-
            // thinking beta header, so Anthropic emits at most one thinking
            // block per turn — `ChatSession` persists a single
            // `thinkingContent`/`thinkingSignature` pair to match. If
            // interleaved thinking is ever enabled, this single-pair model
            // breaks (text from all blocks would pair with only the last
            // signature → a replay 400) and must become per-block.
            if !signature.isEmpty {
                pendingThinkingSignature = (index: normalized, signature: signature)
            }
            events.append(.contentBlockStop(index: normalized))
        case .toolUse(let normalized, let callID, let name, let arguments):
            events.append(contentsOf: flushToolCall(
                normalizedIndex: normalized,
                callID: callID,
                name: name,
                arguments: arguments
            ))
        case .serverToolUse(let arguments):
            emitSearchStartedIfNeeded(arguments: arguments, into: &events)
        case .webSearchResult, .none:
            break
        }
        blocks[index] = nil
    }

    // MARK: - Helpers

    private mutating func allocateBlockIndex() -> Int {
        let index = nextBlockIndex
        nextBlockIndex += 1
        return index
    }

    /// Build a `SourceCitation` from a `web_search_result_location` and emit it.
    /// Skips (without dropping the rest of the turn) a citation whose URL is
    /// malformed, mirroring the Responses reducer's per-citation tolerance.
    private mutating func appendCitation(
        _ citation: AnthropicStreamEvent.Citation,
        into events: inout [LLMStreamEvent]
    ) {
        guard let urlString = citation.url, let url = URL(string: urlString) else { return }
        ensureMessageStart(into: &events)
        let ordinal = citationOrdinal
        citationOrdinal += 1
        let echo = ProviderEcho(
            kind: AnthropicWebSearch.echoKind,
            encryptedContent: encryptedContentByURL[urlString],
            encryptedIndex: citation.encryptedIndex
        )
        let source = SourceCitation(
            id: "\(url.absoluteString)#\(ordinal)",
            title: citation.title ?? "",
            url: url,
            snippet: citation.citedText,
            providerEcho: echo
        )
        events.append(.citations([source]))
    }

    /// Parse the accumulated `server_tool_use` arguments for the query and emit
    /// `.searchStarted` once. An unparseable/empty buffer still emits with an
    /// empty query so the affordance fires.
    private mutating func emitSearchStartedIfNeeded(
        arguments: String,
        into events: inout [LLMStreamEvent]
    ) {
        guard !emittedSearchStarted else { return }
        let query = Self.decodeQuery(from: arguments) ?? ""
        events.append(.searchStarted(query: query))
        emittedSearchStarted = true
    }

    private static func decodeQuery(from arguments: String) -> String? {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let value = try? JSONDecoder().decode(QueryArguments.self, from: Data(trimmed.utf8)) else {
            return nil
        }
        return value.query
    }

    private struct QueryArguments: Decodable {
        let query: String?
    }

    /// Emit a client tool call's `.toolUse` (between its already-open
    /// `contentBlockStart` and a closing `contentBlockStop`). A malformed
    /// argument string becomes an `.error` in place of the call; after a prior
    /// error the partial call is dropped silently.
    private mutating func flushToolCall(
        normalizedIndex: Int,
        callID: String,
        name: String,
        arguments: String
    ) -> [LLMStreamEvent] {
        if hadError { return [] }
        guard !name.isEmpty else {
            return [.contentBlockStop(index: normalizedIndex)]
        }
        do {
            let input = try Self.parseArguments(arguments)
            return [
                .toolUse(index: normalizedIndex, id: callID, name: name, input: input, signature: nil),
                .contentBlockStop(index: normalizedIndex),
            ]
        } catch let error as LLMError {
            return [.error(error)]
        } catch {
            return [.error(.decodingFailed(error.localizedDescription))]
        }
    }

    private static func parseArguments(_ arguments: String) throws -> JSONValue {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .object([:]) }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
        } catch {
            throw LLMError.decodingFailed("tool call arguments: \(error.localizedDescription)")
        }
    }

    /// Close any open block that already emitted a `.contentBlockStart` (text,
    /// thinking, or an interrupted tool-use) by emitting its `.contentBlockStop`
    /// in ascending normalized order, and drop the search blocks (which never
    /// emit a normalized start). Balancing the interrupted tool-use's start
    /// keeps the event stream well-formed even when a transport error cuts it
    /// off mid-arguments — its `.toolUse` payload is intentionally *not* emitted
    /// (the partial args are unparseable noise). Idempotent: clears `blocks`, so
    /// a second call is a no-op. Used by both `closeOut()` and the error path so
    /// `.error` lands immediately before the terminal `.messageComplete`.
    mutating func closeOpenBlocks() -> [LLMStreamEvent] {
        var stops: [Int] = []
        for block in blocks.values {
            switch block {
            case .text(let normalized), .thinking(let normalized, _):
                stops.append(normalized)
            case .toolUse(let normalized, _, _, _):
                stops.append(normalized)
            case .serverToolUse, .webSearchResult:
                break
            }
        }
        blocks.removeAll()
        return stops.sorted().map { .contentBlockStop(index: $0) }
    }

    /// Emit close events + `.messageComplete` exactly once. Both `message_stop`
    /// and the stream-end `finish()` route through here; `emittedComplete`
    /// makes the second call a no-op.
    private mutating func closeOut() -> [LLMStreamEvent] {
        if emittedComplete { return [] }
        var events: [LLMStreamEvent] = []
        ensureMessageStart(into: &events)
        events.append(contentsOf: closeOpenBlocks())
        if let pending = pendingThinkingSignature, !sawRedactedThinking, !hadError {
            events.append(.thinkingSignature(index: pending.index, signature: pending.signature))
        }
        events.append(.messageComplete(usage: TokenUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadInputTokens: cacheReadInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens
        )))
        emittedComplete = true
        return events
    }

    /// Latch any cache token counts the usage payload carries. Only overwrites a
    /// stored value when the payload actually has one, so a later cache-free
    /// `message_delta` can't clobber the counts seen at `message_start`.
    private mutating func captureCacheTokens(from usage: AnthropicStreamEvent.Usage?) {
        if let creation = usage?.cacheCreationInputTokens { cacheCreationInputTokens = creation }
        if let read = usage?.cacheReadInputTokens { cacheReadInputTokens = read }
    }

    private mutating func ensureMessageStart(into events: inout [LLMStreamEvent]) {
        guard !emittedMessageStart else { return }
        events.append(.messageStart(id: capturedID ?? "", model: capturedModel ?? ""))
        emittedMessageStart = true
    }
}
