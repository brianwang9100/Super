import Core
import Foundation
import Testing
@testable import Chat

/// Tests for `OpenAIStreamReducer`'s state machine: messageStart-first
/// invariant, thinking↔text block transitions, tool-call accumulation
/// across argument fragments, surfaced decode errors, and terminal
/// `messageComplete` with captured token usage. The reducer is
/// non-throwing — failures arrive as `.error(...)` events inside the
/// returned arrays so consumers always get a clean stream.
@Suite("OpenAIStreamReducer")
struct OpenAIStreamReducerTests {

    @Test func emitsMessageStartOnFirstChunkWithIDAndModel() {
        var reducer = OpenAIStreamReducer()
        let chunk = OpenAIStreamChunk(
            id: "chatcmpl-1",
            model: "gpt-4o-mini",
            choices: [
                OpenAIStreamChoice(
                    index: 0,
                    delta: OpenAIDelta(
                        role: "assistant",
                        content: nil,
                        reasoningContent: nil,
                        reasoning: nil,
                        toolCalls: nil
                    ),
                    finishReason: nil
                ),
            ],
            usage: nil
        )
        let events = reducer.consume(chunk)
        // Role-only delta with no text/thinking/tool content should not
        // open any block — only capturedID/Model are stashed; messageStart
        // is deferred until something is actually emitted.
        #expect(events.isEmpty)
    }

    @Test func messageStartIsEmittedOnceAcrossChunks() {
        var reducer = OpenAIStreamReducer()
        let first = reducer.consume(makeTextChunk(id: "x", model: "m", text: "a"))
        let second = reducer.consume(makeTextChunk(id: "x", model: "m", text: "b"))

        let firstStarts = first.filter { if case .messageStart = $0 { return true } else { return false } }
        let secondStarts = second.filter { if case .messageStart = $0 { return true } else { return false } }
        #expect(firstStarts.count == 1)
        #expect(secondStarts.isEmpty)
    }

    @Test func messageStartFiresWithEmptyIDAndModelWhenUpstreamOmitsThem() {
        var reducer = OpenAIStreamReducer()
        let events = reducer.consume(OpenAIStreamChunk(
            id: nil, model: nil,
            choices: [OpenAIStreamChoice(
                index: 0,
                delta: OpenAIDelta(
                    role: "assistant", content: "hello",
                    reasoningContent: nil, reasoning: nil, toolCalls: nil
                ),
                finishReason: nil
            ),],
            usage: nil
        ))
        // Contract: messageStart precedes any content event, even when
        // the proxy strips id/model. Empty strings substitute.
        #expect(events.first == .messageStart(id: "", model: ""))
    }

    @Test func textDeltaOpensTextBlockAndStreamsContent() {
        var reducer = OpenAIStreamReducer()
        _ = reducer.consume(makeTextChunk(id: "x", model: "m", text: "Hello"))
        let events = reducer.consume(makeTextChunk(id: "x", model: "m", text: " world"))
        #expect(events == [.textDelta(index: 0, text: " world")])
    }

    @Test func reasoningDeltaOpensThinkingBlockBeforeText() {
        var reducer = OpenAIStreamReducer()
        let first = reducer.consume(OpenAIStreamChunk(
            id: "x", model: "m",
            choices: [OpenAIStreamChoice(
                index: 0,
                delta: OpenAIDelta(
                    role: "assistant",
                    content: nil,
                    reasoningContent: "thinking…",
                    reasoning: nil,
                    toolCalls: nil
                ),
                finishReason: nil
            ),],
            usage: nil
        ))
        #expect(first == [
            .messageStart(id: "x", model: "m"),
            .contentBlockStart(index: 0, type: .thinking),
            .thinkingDelta(index: 0, text: "thinking…"),
        ])
    }

    @Test func textArrivingAfterThinkingClosesThinkingAndOpensText() {
        var reducer = OpenAIStreamReducer()
        _ = reducer.consume(OpenAIStreamChunk(
            id: "x", model: "m",
            choices: [OpenAIStreamChoice(
                index: 0,
                delta: OpenAIDelta(
                    role: "assistant", content: nil,
                    reasoningContent: "ponder", reasoning: nil, toolCalls: nil
                ),
                finishReason: nil
            ),],
            usage: nil
        ))
        let events = reducer.consume(makeTextChunk(id: "x", model: "m", text: "answer"))
        #expect(events == [
            .contentBlockStop(index: 0),
            .contentBlockStart(index: 1, type: .text),
            .textDelta(index: 1, text: "answer"),
        ])
    }

    @Test func recognizesOpenAIReasoningFieldName() {
        var reducer = OpenAIStreamReducer()
        let events = reducer.consume(OpenAIStreamChunk(
            id: "x", model: "m",
            choices: [OpenAIStreamChoice(
                index: 0,
                delta: OpenAIDelta(
                    role: "assistant", content: nil,
                    reasoningContent: nil,
                    reasoning: "o-series field name",
                    toolCalls: nil
                ),
                finishReason: nil
            ),],
            usage: nil
        ))
        #expect(events.contains(.thinkingDelta(index: 0, text: "o-series field name")))
    }

    @Test func toolCallArgumentsAccumulateAcrossFragments() {
        var reducer = OpenAIStreamReducer()
        _ = reducer.consume(makeToolCallStart(name: "lookup", id: "call_1", argsFragment: "{\"q\":"))
        _ = reducer.consume(makeToolCallContinuation(argsFragment: "\"swift\"}"))
        let finishEvents = reducer.consume(OpenAIStreamChunk(
            id: nil, model: nil,
            choices: [OpenAIStreamChoice(index: 0, delta: nil, finishReason: "tool_calls")],
            usage: nil
        ))
        let toolUse = finishEvents.compactMap { event -> JSONValue? in
            if case .toolUse(_, _, _, let input) = event { return input }
            return nil
        }
        #expect(toolUse == [.object(["q": .string("swift")])])
    }

    @Test func toolCallFragmentAndFinishReasonInSameChunkStillFlushes() {
        var reducer = OpenAIStreamReducer()
        _ = reducer.consume(makeToolCallStart(name: "lookup", id: "call_same", argsFragment: "{\"q\":"))
        // Final chunk delivers the closing argument fragment AND the
        // finish_reason in the same payload — a real OpenAI server
        // behavior the earlier code path didn't have explicit coverage for.
        let events = reducer.consume(OpenAIStreamChunk(
            id: nil, model: nil,
            choices: [OpenAIStreamChoice(
                index: 0,
                delta: OpenAIDelta(
                    role: nil, content: nil,
                    reasoningContent: nil, reasoning: nil,
                    toolCalls: [OpenAIToolCallDelta(
                        index: 0, id: nil, type: nil,
                        function: OpenAIFunctionDelta(name: nil, arguments: "\"swift\"}")
                    ),]
                ),
                finishReason: "tool_calls"
            ),],
            usage: nil
        ))
        let toolUse = events.compactMap { event -> JSONValue? in
            if case .toolUse(_, _, _, let input) = event { return input }
            return nil
        }
        #expect(toolUse == [.object(["q": .string("swift")])])
    }

    @Test func multipleToolCallsFlushInIndexOrder() {
        var reducer = OpenAIStreamReducer()
        _ = reducer.consume(makeMultiToolCallStart())
        let finish = reducer.consume(OpenAIStreamChunk(
            id: nil, model: nil,
            choices: [OpenAIStreamChoice(index: 0, delta: nil, finishReason: "tool_calls")],
            usage: nil
        ))
        let names = finish.compactMap { event -> String? in
            if case .toolUse(_, _, let name, _) = event { return name }
            return nil
        }
        #expect(names == ["alpha", "beta"])
    }

    @Test func malformedToolCallArgumentsEmitErrorEventInsteadOfThrowing() {
        var reducer = OpenAIStreamReducer()
        _ = reducer.consume(makeToolCallStart(name: "broken", id: "call_2", argsFragment: "{not json"))
        let events = reducer.consume(OpenAIStreamChunk(
            id: nil, model: nil,
            choices: [OpenAIStreamChoice(index: 0, delta: nil, finishReason: "tool_calls")],
            usage: nil
        ))
        let errors = events.compactMap { event -> LLMError? in
            if case .error(let error) = event { return error }
            return nil
        }
        #expect(errors.count == 1)
        if case .decodingFailed = errors.first {} else {
            Issue.record("expected .decodingFailed, got \(String(describing: errors.first))")
        }
        // Reducer must not yield a toolUse for the malformed call.
        let toolUses = events.filter { if case .toolUse = $0 { return true } else { return false } }
        #expect(toolUses.isEmpty)
    }

    @Test func malformedToolCallDoesNotBlockSiblingCallsFromFlushing() {
        var reducer = OpenAIStreamReducer()
        // Broken call at index 0, well-formed call at index 1, finish in
        // the same chunk so flushToolCalls runs immediately.
        let events = reducer.consume(OpenAIStreamChunk(
            id: "x", model: "m",
            choices: [OpenAIStreamChoice(
                index: 0,
                delta: OpenAIDelta(
                    role: "assistant", content: nil,
                    reasoningContent: nil, reasoning: nil,
                    toolCalls: [
                        OpenAIToolCallDelta(
                            index: 0, id: "broken", type: "function",
                            function: OpenAIFunctionDelta(name: "broken", arguments: "{nope")
                        ),
                        OpenAIToolCallDelta(
                            index: 1, id: "good", type: "function",
                            function: OpenAIFunctionDelta(name: "good", arguments: "{}")
                        ),
                    ]
                ),
                finishReason: "tool_calls"
            ),],
            usage: nil
        ))
        let toolUseNames = events.compactMap { event -> String? in
            if case .toolUse(_, _, let name, _) = event { return name }
            return nil
        }
        let errors = events.compactMap { event -> LLMError? in
            if case .error(let error) = event { return error }
            return nil
        }
        // Well-formed sibling still surfaces; the broken one is reported
        // as a single decode error.
        #expect(toolUseNames == ["good"])
        #expect(errors.count == 1)
        if case .decodingFailed = errors.first { } else {
            Issue.record("expected .decodingFailed for broken sibling, got \(String(describing: errors.first))")
        }
    }

    @Test func finishEmitsMessageCompleteWithCapturedUsage() {
        var reducer = OpenAIStreamReducer()
        _ = reducer.consume(makeTextChunk(id: "x", model: "m", text: "hi"))
        _ = reducer.consume(OpenAIStreamChunk(
            id: nil, model: nil,
            choices: nil,
            usage: OpenAIUsage(promptTokens: 4, completionTokens: 2)
        ))
        let events = reducer.finish()
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 4, outputTokens: 2)))
    }

    @Test func finishIsIdempotent() {
        var reducer = OpenAIStreamReducer()
        _ = reducer.consume(makeTextChunk(id: "x", model: "m", text: "hi"))
        _ = reducer.finish()
        #expect(reducer.finish().isEmpty)
    }

    @Test func finishWithoutUsageEmitsZeroUsage() {
        var reducer = OpenAIStreamReducer()
        _ = reducer.consume(makeTextChunk(id: "x", model: "m", text: "hi"))
        let events = reducer.finish()
        #expect(events.contains(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0))))
    }

    @Test func finishOnFreshReducerStillEmitsMessageStartAndComplete() {
        var reducer = OpenAIStreamReducer()
        // No chunks consumed. finish() still has to produce a complete,
        // contract-conforming stream so consumers downstream of provider
        // pre-flight failures (unsupported model, encoding error) don't
        // hang waiting for messageComplete.
        let events = reducer.finish()
        #expect(events.first == .messageStart(id: "", model: ""))
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    private func makeTextChunk(id: String, model: String, text: String) -> OpenAIStreamChunk {
        OpenAIStreamChunk(
            id: id, model: model,
            choices: [OpenAIStreamChoice(
                index: 0,
                delta: OpenAIDelta(
                    role: nil, content: text,
                    reasoningContent: nil, reasoning: nil, toolCalls: nil
                ),
                finishReason: nil
            ),],
            usage: nil
        )
    }

    private func makeToolCallStart(name: String, id: String, argsFragment: String) -> OpenAIStreamChunk {
        OpenAIStreamChunk(
            id: "x", model: "m",
            choices: [OpenAIStreamChoice(
                index: 0,
                delta: OpenAIDelta(
                    role: "assistant", content: nil,
                    reasoningContent: nil, reasoning: nil,
                    toolCalls: [OpenAIToolCallDelta(
                        index: 0, id: id, type: "function",
                        function: OpenAIFunctionDelta(name: name, arguments: argsFragment)
                    ),]
                ),
                finishReason: nil
            ),],
            usage: nil
        )
    }

    private func makeToolCallContinuation(argsFragment: String) -> OpenAIStreamChunk {
        OpenAIStreamChunk(
            id: nil, model: nil,
            choices: [OpenAIStreamChoice(
                index: 0,
                delta: OpenAIDelta(
                    role: nil, content: nil,
                    reasoningContent: nil, reasoning: nil,
                    toolCalls: [OpenAIToolCallDelta(
                        index: 0, id: nil, type: nil,
                        function: OpenAIFunctionDelta(name: nil, arguments: argsFragment)
                    ),]
                ),
                finishReason: nil
            ),],
            usage: nil
        )
    }

    private func makeMultiToolCallStart() -> OpenAIStreamChunk {
        OpenAIStreamChunk(
            id: "x", model: "m",
            choices: [OpenAIStreamChoice(
                index: 0,
                delta: OpenAIDelta(
                    role: "assistant", content: nil,
                    reasoningContent: nil, reasoning: nil,
                    toolCalls: [
                        OpenAIToolCallDelta(
                            index: 0, id: "call_a", type: "function",
                            function: OpenAIFunctionDelta(name: "alpha", arguments: "{}")
                        ),
                        OpenAIToolCallDelta(
                            index: 1, id: "call_b", type: "function",
                            function: OpenAIFunctionDelta(name: "beta", arguments: "{}")
                        ),
                    ]
                ),
                finishReason: nil
            ),],
            usage: nil
        )
    }
}
