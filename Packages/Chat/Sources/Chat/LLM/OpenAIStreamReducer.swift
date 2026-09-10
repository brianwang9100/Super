import Core
import Foundation

/// Normalizes one Chat Completions stream, including fragmented tool calls.
struct OpenAIStreamReducer {
    let requiresCompleteResponse: Bool
    private var hasNativeCompletion = false

    init(requiresCompleteResponse: Bool = false) {
        self.requiresCompleteResponse = requiresCompleteResponse
    }

    private var emittedMessageStart = false
    /// Defer messageStart until content; proxies that strip identifiers fall back to empty strings.
    private var capturedID: String?
    private var capturedModel: String?

    /// Our monotonic content index, independent of provider choice and tool-call indexes.
    private var nextBlockIndex = 0
    private var openTextBlock: Int?
    private var openThinkingBlock: Int?

    /// Keyed by the provider's tool index; arguments stay fragmented until flush.
    private var toolCallBuilders: [Int: ToolCallBuilder] = [:]

    /// The final usage chunk is retained for messageComplete.
    private var capturedUsage: TokenUsage?

    private var emittedComplete = false
    private var hadError = false

    /// Always emits `.messageStart` before content, even when identifiers are absent.
    mutating func consume(_ chunk: OpenAIStreamChunk) -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []

        if let id = chunk.id { capturedID = id }
        if let model = chunk.model { capturedModel = model }

        if let usage = chunk.usage,
           let input = usage.promptTokens,
           let output = usage.completionTokens {
            capturedUsage = TokenUsage(
                inputTokens: input,
                outputTokens: output,
                cacheReadInputTokens: usage.promptTokensDetails?.cachedTokens
            )
        }

        guard let choice = chunk.choices?.first else {
            return events
        }

        if requiresCompleteResponse && (hadError || emittedComplete) { return events }

        if let delta = choice.delta {
            if requiresCompleteResponse, let refusal = delta.refusal, !refusal.isEmpty {
                ensureMessageStart(into: &events)
                events.append(contentsOf: closeOpenContentBlocks())
                hadError = true
                events.append(.error(.providerError(code: "refusal", message: "OpenAI declined to complete the response.")))
                return events
            }
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

        if let reason = choice.finishReason {
            if requiresCompleteResponse {
                let completeTools = reason == "tool_calls" && !toolCallBuilders.isEmpty
                    && toolCallBuilders.values.allSatisfy { $0.id?.isEmpty == false && $0.name?.isEmpty == false }
                hasNativeCompletion = reason == "stop" || completeTools
                if !hasNativeCompletion {
                    ensureMessageStart(into: &events)
                    events.append(contentsOf: closeOpenContentBlocks())
                    hadError = true
                    events.append(.error(.providerError(code: "incomplete_response", message: "OpenAI response ended with \(reason).")))
                }
            }
            // Merge arguments from the same chunk before closing on finishReason.
            ensureMessageStart(into: &events)
            events.append(contentsOf: closeOpenContentBlocks())
            events.append(contentsOf: flushToolCalls())
        }

        return events
    }

    /// Idempotent EOF flush, including unfinished blocks and tool calls.
    mutating func finish() -> [LLMStreamEvent] {
        if emittedComplete { return [] }
        var events: [LLMStreamEvent] = []
        ensureMessageStart(into: &events)
        events.append(contentsOf: closeOpenContentBlocks())
        events.append(contentsOf: flushToolCalls())
        if requiresCompleteResponse && !hasNativeCompletion && !hadError {
            hadError = true
            events.append(.error(.providerError(code: "incomplete_response", message: "OpenAI stream ended without successful completion.")))
        }
        let usage = capturedUsage ?? TokenUsage(inputTokens: 0, outputTokens: 0)
        events.append(.messageComplete(usage: usage))
        emittedComplete = true
        return events
    }

    var hasErrored: Bool { hadError }

    /// Preserve an adapter's existing error when its final flush runs.
    mutating func markErrored() {
        hadError = true
    }

    private mutating func ensureMessageStart(into events: inout [LLMStreamEvent]) {
        guard !emittedMessageStart else { return }
        events.append(.messageStart(id: capturedID ?? "", model: capturedModel ?? ""))
        emittedMessageStart = true
    }

    private mutating func openTextBlock(into events: inout [LLMStreamEvent]) -> Int {
        if let existing = openTextBlock { return existing }
        let index = nextBlockIndex
        nextBlockIndex += 1
        openTextBlock = index
        events.append(.contentBlockStart(index: index, type: .text))
        return index
    }

    private mutating func openThinkingBlock(into events: inout [LLMStreamEvent]) -> Int {
        if let existing = openThinkingBlock { return existing }
        let index = nextBlockIndex
        nextBlockIndex += 1
        openThinkingBlock = index
        events.append(.contentBlockStart(index: index, type: .thinking))
        return index
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

    /// Flushes in provider tool-index order. Malformed arguments emit an error while other calls continue.
    private mutating func flushToolCalls() -> [LLMStreamEvent] {
        guard !toolCallBuilders.isEmpty else { return [] }
        if requiresCompleteResponse && hadError {
            toolCallBuilders.removeAll()
            return []
        }
        var events: [LLMStreamEvent] = []
        let ordered = toolCallBuilders.sorted { $0.key < $1.key }
        for (_, builder) in ordered {
            guard let id = builder.id, let name = builder.name else { continue }
            do {
                let input = try builder.parsedArguments()
                let blockIndex = nextBlockIndex
                nextBlockIndex += 1
                events.append(.contentBlockStart(index: blockIndex, type: .toolUse))
                events.append(.toolUse(index: blockIndex, id: id, name: name, input: input, signature: builder.signature))
                events.append(.contentBlockStop(index: blockIndex))
            } catch let error as LLMError {
                hadError = true
                events.append(.error(error))
            } catch {
                hadError = true
                events.append(.error(.decodingFailed(error.localizedDescription)))
            }
        }
        toolCallBuilders.removeAll()
        return events
    }
}

private struct ToolCallBuilder {
    var id: String?
    var name: String?
    var arguments: String = ""
    /// Gemini's thought signature must survive fragmented calls for next-turn replay.
    var signature: String?

    mutating func merge(_ fragment: OpenAIToolCallDelta) {
        if let newID = fragment.id { id = newID }
        if let newName = fragment.function?.name { name = newName }
        if let argsFragment = fragment.function?.arguments {
            arguments.append(argsFragment)
        }
        if let newSignature = fragment.extraContent?.google?.thoughtSignature, !newSignature.isEmpty {
            signature = newSignature
        }
    }

    /// Empty arguments become an empty object.
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
