import Core
import Foundation

/// Stateful reducer that turns the OpenAI Chat Completions stream of
/// `OpenAIStreamChunk`s into the normalized `LLMStreamEvent` sequence
/// every Super UI consumer expects.
///
/// Why a struct: the reducer owns sequencing state for one in-flight
/// response (block indices, partial tool-call buffers, captured token
/// usage) but has no identity beyond the call site that drives it. That
/// matches our project policy of structs-for-data, actors-for-identity.
///
/// The reducer is intentionally pure: callers feed parsed chunks in via
/// `consume(_:)` and a final `finish()`, and receive flat `LLMStreamEvent`
/// arrays back. Neither method throws — internal failures (a malformed
/// tool-call argument string, etc.) are surfaced as `.error(...)` events
/// inside the returned array so the caller can persist whatever did make
/// it through. No I/O (Input/Output), no concurrency, easy to fixture-test.
struct OpenAIStreamReducer {
    /// True after we have emitted `.messageStart`. Prevents duplicate
    /// emission across chunks (OpenAI repeats `id` and `model` on every
    /// chunk; we emit on first-seen).
    private var emittedMessageStart = false
    /// Captured from the first chunk that reports them; used to defer
    /// `.messageStart` until any content event would be emitted, and to
    /// fall back to empty strings when the upstream proxy strips the
    /// identifying fields.
    private var capturedID: String?
    private var capturedModel: String?

    /// Monotonic content-block index assigned to each new text / thinking /
    /// tool-use block we open. Distinct from OpenAI's `choices[i].index`
    /// (which is the choice index — always 0 for our `n=1` requests) and
    /// distinct from `toolCalls[i].index` (which scopes argument fragments
    /// to a tool call within a choice).
    private var nextBlockIndex = 0
    private var openTextBlock: Int?
    private var openThinkingBlock: Int?

    /// Partial tool-call accumulators keyed by OpenAI's per-choice tool
    /// index. Arguments arrive as a fragmented JSON string and are joined
    /// here until the call is flushed at `finishReason` or `finish()`.
    private var toolCallBuilders: [Int: ToolCallBuilder] = [:]

    /// Latest `usage` block we have seen. OpenAI emits this on the final
    /// chunk when `stream_options.include_usage = true`; absent on
    /// intermediate chunks. Stashed here so `finish()` can attach it.
    private var capturedUsage: TokenUsage?

    /// True after we have emitted `.messageComplete`. Guards against
    /// double-emission if `finish()` is called more than once.
    private var emittedComplete = false

    /// Process one decoded SSE (Server-Sent Events) chunk and return the
    /// normalized events it produced. Order within the returned array
    /// reflects the order downstream consumers should observe them in.
    /// `messageStart` is always emitted before any content event from the
    /// same call, even when the upstream chunk lacks `id`/`model`
    /// (placeholders are substituted so the contract holds).
    mutating func consume(_ chunk: OpenAIStreamChunk) -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []

        if let id = chunk.id { capturedID = id }
        if let model = chunk.model { capturedModel = model }

        if let usage = chunk.usage,
           let input = usage.promptTokens,
           let output = usage.completionTokens {
            capturedUsage = TokenUsage(inputTokens: input, outputTokens: output)
        }

        guard let choice = chunk.choices?.first else {
            return events
        }

        if let delta = choice.delta {
            if let thinkingText = delta.reasoningContent ?? delta.reasoning,
               !thinkingText.isEmpty {
                ensureMessageStart(into: &events)
                let index = openThinkingBlock(into: &events)
                events.append(.thinkingDelta(index: index, text: thinkingText))
            }

            if let textDelta = delta.content, !textDelta.isEmpty {
                ensureMessageStart(into: &events)
                if let thinking = openThinkingBlock {
                    events.append(.contentBlockStop(index: thinking))
                    openThinkingBlock = nil
                }
                let index = openTextBlock(into: &events)
                events.append(.textDelta(index: index, text: textDelta))
            }

            if let toolCalls = delta.toolCalls {
                for fragment in toolCalls {
                    let key = fragment.index ?? 0
                    var builder = toolCallBuilders[key] ?? ToolCallBuilder()
                    builder.merge(fragment)
                    toolCallBuilders[key] = builder
                }
            }
        }

        if choice.finishReason != nil {
            // The accumulated tool-call builders may have been populated by
            // the same chunk's `delta.tool_calls`; we always merge first,
            // then close on `finishReason`.
            ensureMessageStart(into: &events)
            events.append(contentsOf: closeOpenContentBlocks())
            events.append(contentsOf: flushToolCalls())
        }

        return events
    }

    /// Final-flush hook. Closes any blocks that were still open (e.g. when
    /// the upstream stream ended without a `finish_reason`), flushes any
    /// pending tool-call builders, and emits the terminal
    /// `.messageComplete(usage:)`. Idempotent: returns an empty array on
    /// subsequent calls.
    mutating func finish() -> [LLMStreamEvent] {
        if emittedComplete { return [] }
        var events: [LLMStreamEvent] = []
        ensureMessageStart(into: &events)
        events.append(contentsOf: closeOpenContentBlocks())
        events.append(contentsOf: flushToolCalls())
        let usage = capturedUsage ?? TokenUsage(inputTokens: 0, outputTokens: 0)
        events.append(.messageComplete(usage: usage))
        emittedComplete = true
        return events
    }

    /// Emits `.messageStart` once, before any content or terminal event,
    /// substituting empty strings when the upstream chunk did not carry
    /// `id`/`model`. The contract that consumers see `.messageStart` first
    /// is enforced here so callers don't have to.
    private mutating func ensureMessageStart(into events: inout [LLMStreamEvent]) {
        guard !emittedMessageStart else { return }
        events.append(.messageStart(id: capturedID ?? "", model: capturedModel ?? ""))
        emittedMessageStart = true
    }

    /// Opens a text block if none is open and returns its index. Returns
    /// the existing block's index when one is already open. The caller
    /// uses the returned index directly so we never need a force-unwrap on
    /// `openTextBlock`.
    private mutating func openTextBlock(into events: inout [LLMStreamEvent]) -> Int {
        if let existing = openTextBlock { return existing }
        let index = nextBlockIndex
        nextBlockIndex += 1
        openTextBlock = index
        events.append(.contentBlockStart(index: index, type: .text))
        return index
    }

    /// Opens a thinking block if none is open and returns its index.
    /// Returns the existing block's index when one is already open.
    private mutating func openThinkingBlock(into events: inout [LLMStreamEvent]) -> Int {
        if let existing = openThinkingBlock { return existing }
        let index = nextBlockIndex
        nextBlockIndex += 1
        openThinkingBlock = index
        events.append(.contentBlockStart(index: index, type: .thinking))
        return index
    }

    /// Closes whichever content block (text or thinking) is currently
    /// open. `openTextBlock` and `openThinkingBlock` are mutually
    /// exclusive by construction — `consume(_:)` closes thinking before
    /// opening text, and never opens thinking after text in the same
    /// stream — so the close order here is informational, not load-bearing.
    private mutating func closeOpenContentBlocks() -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []
        if let thinking = openThinkingBlock {
            events.append(.contentBlockStop(index: thinking))
            openThinkingBlock = nil
        }
        if let text = openTextBlock {
            events.append(.contentBlockStop(index: text))
            openTextBlock = nil
        }
        return events
    }

    /// Flushes accumulated tool-call builders in OpenAI-index order so the
    /// emitted `.toolUse` events match the model's intent. Each tool call
    /// gets its own block (start → toolUse → stop). A malformed argument
    /// string surfaces as an `.error(.decodingFailed(...))` event in
    /// place of the tool-use triplet — flushing continues for any
    /// remaining well-formed calls so the consumer sees as much of the
    /// turn as actually arrived.
    private mutating func flushToolCalls() -> [LLMStreamEvent] {
        guard !toolCallBuilders.isEmpty else { return [] }
        var events: [LLMStreamEvent] = []
        let ordered = toolCallBuilders.sorted { $0.key < $1.key }
        for (_, builder) in ordered {
            guard let id = builder.id, let name = builder.name else { continue }
            do {
                let input = try builder.parsedArguments()
                let blockIndex = nextBlockIndex
                nextBlockIndex += 1
                events.append(.contentBlockStart(index: blockIndex, type: .toolUse))
                events.append(.toolUse(index: blockIndex, id: id, name: name, input: input))
                events.append(.contentBlockStop(index: blockIndex))
            } catch let error as LLMError {
                events.append(.error(error))
            } catch {
                events.append(.error(.decodingFailed(error.localizedDescription)))
            }
        }
        toolCallBuilders.removeAll()
        return events
    }
}

/// Per-tool-call accumulator. OpenAI streams a tool call's `arguments`
/// field as a sequence of JSON-string fragments; we glue them back together
/// and parse once at flush time.
private struct ToolCallBuilder {
    var id: String?
    var name: String?
    var arguments: String = ""

    mutating func merge(_ fragment: OpenAIToolCallDelta) {
        if let newID = fragment.id { id = newID }
        if let newName = fragment.function?.name { name = newName }
        if let argsFragment = fragment.function?.arguments {
            arguments.append(argsFragment)
        }
    }

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
