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
/// arrays back. No I/O (Input/Output), no concurrency, easy to fixture-test.
struct OpenAIStreamReducer {
    /// True after we have emitted `.messageStart`. Prevents duplicate
    /// emission across chunks (OpenAI repeats `id` and `model` on every
    /// chunk; we emit on first-seen).
    private var emittedMessageStart = false
    /// Captured from the first chunk; used to defer `.messageStart` if
    /// the first chunk is incomplete (e.g. proxies that strip headers).
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
    /// here until the call is flushed at `finishReason`.
    private var toolCallBuilders: [Int: ToolCallBuilder] = [:]

    /// Latest `usage` block we have seen. OpenAI emits this on the final
    /// chunk when `stream_options.include_usage = true`; absent on
    /// intermediate chunks. Stashed here so `finish()` can attach it.
    private var capturedUsage: TokenUsage?

    /// True after we have emitted `.messageComplete`. Guards against
    /// double-emission if `finish()` is called more than once.
    private var emittedComplete = false

    /// Process one decoded SSE chunk and return the normalized events it
    /// produced. Order within the returned array reflects the order
    /// downstream consumers should observe them in.
    mutating func consume(_ chunk: OpenAIStreamChunk) throws -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []

        if !emittedMessageStart {
            if let id = chunk.id { capturedID = id }
            if let model = chunk.model { capturedModel = model }
            if let id = capturedID, let model = capturedModel {
                events.append(.messageStart(id: id, model: model))
                emittedMessageStart = true
            }
        }

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
                events.append(contentsOf: openThinkingIfNeeded())
                events.append(.thinkingDelta(index: openThinkingBlock!, text: thinkingText))
            }

            if let textDelta = delta.content, !textDelta.isEmpty {
                if let thinking = openThinkingBlock {
                    events.append(.contentBlockStop(index: thinking))
                    openThinkingBlock = nil
                }
                events.append(contentsOf: openTextIfNeeded())
                events.append(.textDelta(index: openTextBlock!, text: textDelta))
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
            events.append(contentsOf: closeOpenContentBlocks())
            events.append(contentsOf: try flushToolCalls())
        }

        return events
    }

    /// Final-flush hook. Closes any blocks that were still open (e.g. when
    /// the upstream stream ended without a `finish_reason`) and emits the
    /// terminal `.messageComplete(usage:)`. Idempotent: returns an empty
    /// array on subsequent calls.
    mutating func finish() throws -> [LLMStreamEvent] {
        if emittedComplete { return [] }
        var events: [LLMStreamEvent] = []
        events.append(contentsOf: closeOpenContentBlocks())
        events.append(contentsOf: try flushToolCalls())
        let usage = capturedUsage ?? TokenUsage(inputTokens: 0, outputTokens: 0)
        events.append(.messageComplete(usage: usage))
        emittedComplete = true
        return events
    }

    private mutating func openTextIfNeeded() -> [LLMStreamEvent] {
        if openTextBlock != nil { return [] }
        let index = nextBlockIndex
        nextBlockIndex += 1
        openTextBlock = index
        return [.contentBlockStart(index: index, type: .text)]
    }

    private mutating func openThinkingIfNeeded() -> [LLMStreamEvent] {
        if openThinkingBlock != nil { return [] }
        let index = nextBlockIndex
        nextBlockIndex += 1
        openThinkingBlock = index
        return [.contentBlockStart(index: index, type: .thinking)]
    }

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
    /// gets its own block (start → toolUse → stop). Throws
    /// `LLMError.decodingFailed` if the accumulated argument string isn't
    /// valid JSON — a malformed tool call breaks the turn semantically, so
    /// we don't paper over it.
    private mutating func flushToolCalls() throws -> [LLMStreamEvent] {
        guard !toolCallBuilders.isEmpty else { return [] }
        var events: [LLMStreamEvent] = []
        let ordered = toolCallBuilders.sorted { $0.key < $1.key }
        for (_, builder) in ordered {
            guard let id = builder.id, let name = builder.name else { continue }
            let blockIndex = nextBlockIndex
            nextBlockIndex += 1
            events.append(.contentBlockStart(index: blockIndex, type: .toolUse))
            let input = try builder.parsedArguments()
            events.append(.toolUse(index: blockIndex, id: id, name: name, input: input))
            events.append(.contentBlockStop(index: blockIndex))
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
