import Core
import Foundation
import Testing
@testable import Chat

/// Tests for `OpenAIStreamReducer`'s state machine: messageStart emission,
/// thinking↔text block transitions, tool-call accumulation across argument
/// fragments, and terminal `messageComplete` with captured token usage.
@Suite("OpenAIStreamReducer")
struct OpenAIStreamReducerTests {

    @Test func emitsMessageStartOnFirstChunkWithIDAndModel() throws {
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
                )
            ],
            usage: nil
        )
        let events = try reducer.consume(chunk)
        #expect(events == [.messageStart(id: "chatcmpl-1", model: "gpt-4o-mini")])
    }

    @Test func messageStartIsEmittedOnceAcrossChunks() throws {
        var reducer = OpenAIStreamReducer()
        _ = try reducer.consume(makeTextChunk(id: "x", model: "m", text: "a"))
        let events = try reducer.consume(makeTextChunk(id: "x", model: "m", text: "b"))
        for event in events {
            if case .messageStart = event {
                Issue.record("messageStart emitted twice")
            }
        }
    }

    @Test func textDeltaOpensTextBlockAndStreamsContent() throws {
        var reducer = OpenAIStreamReducer()
        _ = try reducer.consume(makeTextChunk(id: "x", model: "m", text: "Hello"))
        let events = try reducer.consume(makeTextChunk(id: "x", model: "m", text: " world"))
        #expect(events == [.textDelta(index: 0, text: " world")])
    }

    @Test func reasoningDeltaOpensThinkingBlockBeforeText() throws {
        var reducer = OpenAIStreamReducer()
        let first = try reducer.consume(OpenAIStreamChunk(
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
            )],
            usage: nil
        ))
        #expect(first == [
            .messageStart(id: "x", model: "m"),
            .contentBlockStart(index: 0, type: .thinking),
            .thinkingDelta(index: 0, text: "thinking…"),
        ])
    }

    @Test func textArrivingAfterThinkingClosesThinkingAndOpensText() throws {
        var reducer = OpenAIStreamReducer()
        _ = try reducer.consume(OpenAIStreamChunk(
            id: "x", model: "m",
            choices: [OpenAIStreamChoice(
                index: 0,
                delta: OpenAIDelta(
                    role: "assistant", content: nil,
                    reasoningContent: "ponder", reasoning: nil, toolCalls: nil
                ),
                finishReason: nil
            )],
            usage: nil
        ))
        let events = try reducer.consume(makeTextChunk(id: "x", model: "m", text: "answer"))
        #expect(events == [
            .contentBlockStop(index: 0),
            .contentBlockStart(index: 1, type: .text),
            .textDelta(index: 1, text: "answer"),
        ])
    }

    @Test func recognizesOpenAIReasoningFieldName() throws {
        var reducer = OpenAIStreamReducer()
        let events = try reducer.consume(OpenAIStreamChunk(
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
            )],
            usage: nil
        ))
        #expect(events.contains(.thinkingDelta(index: 0, text: "o-series field name")))
    }

    @Test func toolCallArgumentsAccumulateAcrossFragments() throws {
        var reducer = OpenAIStreamReducer()
        _ = try reducer.consume(makeToolCallStart(name: "lookup", id: "call_1", argsFragment: "{\"q\":"))
        _ = try reducer.consume(makeToolCallContinuation(argsFragment: "\"swift\"}"))
        let finishEvents = try reducer.consume(OpenAIStreamChunk(
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

    @Test func multipleToolCallsFlushInIndexOrder() throws {
        var reducer = OpenAIStreamReducer()
        _ = try reducer.consume(makeMultiToolCallStart())
        let finish = try reducer.consume(OpenAIStreamChunk(
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

    @Test func malformedToolCallArgumentsThrowDecodingFailure() throws {
        var reducer = OpenAIStreamReducer()
        _ = try reducer.consume(makeToolCallStart(name: "broken", id: "call_2", argsFragment: "{not json"))
        do {
            _ = try reducer.consume(OpenAIStreamChunk(
                id: nil, model: nil,
                choices: [OpenAIStreamChoice(index: 0, delta: nil, finishReason: "tool_calls")],
                usage: nil
            ))
            Issue.record("Expected throw on malformed tool arguments")
        } catch let error as LLMError {
            if case .decodingFailed = error { return }
            Issue.record("Expected .decodingFailed, got \(error)")
        }
    }

    @Test func finishEmitsMessageCompleteWithCapturedUsage() throws {
        var reducer = OpenAIStreamReducer()
        _ = try reducer.consume(makeTextChunk(id: "x", model: "m", text: "hi"))
        _ = try reducer.consume(OpenAIStreamChunk(
            id: nil, model: nil,
            choices: nil,
            usage: OpenAIUsage(promptTokens: 4, completionTokens: 2)
        ))
        let events = try reducer.finish()
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 4, outputTokens: 2)))
    }

    @Test func finishIsIdempotent() throws {
        var reducer = OpenAIStreamReducer()
        _ = try reducer.consume(makeTextChunk(id: "x", model: "m", text: "hi"))
        _ = try reducer.finish()
        #expect(try reducer.finish().isEmpty)
    }

    @Test func finishWithoutUsageEmitsZeroUsage() throws {
        var reducer = OpenAIStreamReducer()
        _ = try reducer.consume(makeTextChunk(id: "x", model: "m", text: "hi"))
        let events = try reducer.finish()
        #expect(events.contains(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0))))
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
            )],
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
                    )]
                ),
                finishReason: nil
            )],
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
                    )]
                ),
                finishReason: nil
            )],
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
            )],
            usage: nil
        )
    }
}
