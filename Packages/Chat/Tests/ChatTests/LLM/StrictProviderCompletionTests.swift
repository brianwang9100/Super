import Core
import Foundation
import Testing
@testable import Chat

@Suite("Strict provider completion")
struct StrictProviderCompletionTests {
    enum Backend: String, CaseIterable, Sendable {
        case chat, responses, anthropic, gemini

        var partial: [String] {
            switch self {
            case .chat: [#"{"choices":[{"delta":{"content":"Partial note"}}]}"#]
            case .responses: [#"{"type":"response.output_text.delta","delta":"Partial note"}"#]
            case .anthropic: [
                #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Partial note"}}"#,
                #"{"type":"content_block_stop","index":0}"#,
            ]
            case .gemini: [#"{"candidates":[{"content":{"parts":[{"text":"Partial note"}]}}]}"#]
            }
        }

        var success: [String] {
            switch self {
            case .chat: [#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#]
            case .responses: [#"{"type":"response.completed","response":{"status":"completed"}}"#]
            case .anthropic: [#"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#, #"{"type":"message_stop"}"#]
            case .gemini: [#"{"candidates":[{"finishReason":"STOP"}]}"#]
            }
        }

        var failures: [[String]] {
            switch self {
            case .chat: ["length", "content_filter"].map { ["{\"choices\":[{\"finish_reason\":\"\($0)\"}]}"] }
            case .responses: ["incomplete", "failed", "cancelled"].map { ["{\"type\":\"response.\($0)\",\"response\":{\"status\":\"\($0)\"}}"] }
            case .anthropic: ["max_tokens", "refusal", "pause_turn"].map { ["{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\($0)\"}}", #"{"type":"message_stop"}"#] }
            case .gemini: ["MAX_TOKENS", "SAFETY", "RECITATION"].map { ["{\"candidates\":[{\"finishReason\":\"\($0)\"}]}"] }
            }
        }

        func provider(http: HTTPClient, model: LLMModel) -> any LLMProvider {
            let url = URL(string: "https://example.test/v1")!
            switch self {
            case .chat: return OpenAICompatibleLLMProvider(id: rawValue, displayName: rawValue, model: model, baseURL: url, apiKey: "test", http: http)
            case .responses: return OpenAIResponsesLLMProvider(id: rawValue, displayName: rawValue, model: model, baseURL: url, apiKey: "test", http: http)
            case .anthropic: return AnthropicNativeLLMProvider(id: rawValue, displayName: rawValue, model: model, baseURL: url, apiKey: "test", http: http)
            case .gemini: return GeminiNativeLLMProvider(id: rawValue, displayName: rawValue, model: model, baseURL: url, apiKey: "test", http: http)
            }
        }
    }

    private func collect(_ backend: Backend, frames: [String], strict: Bool, error: Error? = nil) async throws -> [LLMStreamEvent] {
        let http = FakeHTTPClient(chunks: frames.map { Data("data: \($0)\n\n".utf8) }, error: error)
        let model = LLMModel(id: "test", displayName: "Test", supportsThinking: false, supportsTools: true, maxContextTokens: 4096)
        let provider = backend.provider(http: http, model: model)
        var events: [LLMStreamEvent] = []
        for try await event in provider.stream(messages: [.init(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5, options: .init(requiresCompleteResponse: strict)) {
            events.append(event)
        }
        let request = try #require(http.observed.all.first)
        let body = try #require(request.httpBody)
        let bodyString = try #require(String(data: body, encoding: .utf8))
        #expect(!bodyString.contains("requiresCompleteResponse"))
        return events
    }

    private func errors(_ events: [LLMStreamEvent]) -> [LLMError] {
        events.compactMap { if case .error(let error) = $0 { error } else { nil } }
    }

    @Test(arguments: Backend.allCases)
    func partialEOFRequiresNativeCompletion(_ backend: Backend) async throws {
        let events = try await collect(backend, frames: backend.partial, strict: true)
        #expect(events.contains { if case .textDelta(_, "Partial note") = $0 { true } else { false } })
        #expect(errors(events).count == 1)
        #expect(events.dropLast().last.map { if case .error = $0 { true } else { false } } == true)
        #expect(events.last.map { if case .messageComplete = $0 { true } else { false } } == true)
    }

    @Test(arguments: Backend.allCases)
    func successfulNativeCompletionIsAccepted(_ backend: Backend) async throws {
        let events = try await collect(backend, frames: backend.partial + backend.success, strict: true)
        #expect(errors(events).isEmpty)
        #expect(events.filter { if case .messageComplete = $0 { true } else { false } }.count == 1)
    }

    @Test(arguments: Backend.allCases)
    func unsuccessfulNativeTerminationIsRejected(_ backend: Backend) async throws {
        for failure in backend.failures {
            let events = try await collect(backend, frames: backend.partial + failure, strict: true)
            #expect(errors(events).count == 1)
        }
    }

    @Test(arguments: Backend.allCases)
    func defaultModePreservesPartialEOF(_ backend: Backend) async throws {
        let events = try await collect(backend, frames: backend.partial, strict: false)
        #expect(errors(events).isEmpty)
        #expect(events.last.map { if case .messageComplete = $0 { true } else { false } } == true)
    }

    @Test(arguments: Backend.allCases)
    func transportErrorIsNotReplacedByIncompleteError(_ backend: Backend) async throws {
        let events = try await collect(backend, frames: backend.partial, strict: true, error: CancellationError())
        #expect(errors(events) == [.cancelled])
    }
    @Test(arguments: Backend.allCases)
    func malformedFrameCannotBecomeSuccessful(_ backend: Backend) async throws {
        let events = try await collect(backend, frames: backend.partial + ["{broken JSON"] + backend.success, strict: true)
        #expect(errors(events).count == 1)
        #expect(errors(events).first.map { if case .decodingFailed = $0 { true } else { false } } == true)
    }

    @Test(arguments: Backend.allCases)
    func failedTerminationCannotBeOverwrittenBySuccess(_ backend: Backend) async throws {
        let events = try await collect(backend, frames: backend.partial + backend.failures[0] + backend.success, strict: true)
        #expect(errors(events).count == 1)
    }

    @Test func refusalsCannotSaveEarlierText() async throws {
        for (backend, refusal) in [
            (Backend.chat, #"{"choices":[{"delta":{"refusal":"Cannot answer"}}]}"#),
            (Backend.responses, #"{"type":"response.refusal.delta","delta":"Cannot answer"}"#),
        ] {
            let events = try await collect(backend, frames: backend.partial + [refusal] + backend.success, strict: true)
            #expect(errors(events).count == 1)
        }
    }

    @Test func responsesCompletedWithFailedStatusIsRejected() async throws {
        let events = try await collect(.responses, frames: Backend.responses.partial + [#"{"type":"response.completed","response":{"status":"failed"}}"#], strict: true)
        #expect(errors(events).count == 1)
    }

    private func reduce(_ backend: Backend, frames: [String]) throws -> [LLMStreamEvent] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = backend == .gemini ? .useDefaultKeys : .convertFromSnakeCase
        var result: [LLMStreamEvent] = []
        switch backend {
        case .chat:
            var reducer = OpenAIStreamReducer(requiresCompleteResponse: true)
            for frame in frames { result += reducer.consume(try decoder.decode(OpenAIStreamChunk.self, from: Data(frame.utf8))) }
            result += reducer.finish()
            #expect(reducer.finish().isEmpty)
        case .responses:
            var reducer = OpenAIResponsesStreamReducer(requiresCompleteResponse: true)
            for frame in frames { result += reducer.consume(try decoder.decode(OpenAIResponsesStreamEvent.self, from: Data(frame.utf8))) }
            result += reducer.finish()
            #expect(reducer.finish().isEmpty)
        case .anthropic:
            var reducer = AnthropicStreamReducer(requiresCompleteResponse: true)
            for frame in frames { result += reducer.consume(try decoder.decode(AnthropicStreamEvent.self, from: Data(frame.utf8))) }
            result += reducer.finish()
            #expect(reducer.finish().isEmpty)
        case .gemini:
            var reducer = GeminiStreamReducer(requiresCompleteResponse: true)
            for frame in frames { result += reducer.consume(try decoder.decode(GeminiStreamResponse.self, from: Data(frame.utf8))) }
            result += reducer.finish()
            #expect(reducer.finish().isEmpty)
        }
        return result
    }

    @Test(arguments: Backend.allCases)
    func reducersValidateRealWireFixturesAndFinishOnlyOnce(_ backend: Backend) throws {
        #expect(errors(try reduce(backend, frames: backend.partial)).count == 1)
        #expect(errors(try reduce(backend, frames: backend.partial + backend.success)).isEmpty)
        for failure in backend.failures {
            #expect(errors(try reduce(backend, frames: backend.partial + failure)).count == 1)
        }
    }

    @Test func chatRefusalSurvivesLaterTransportError() async throws {
        let events = try await collect(.chat, frames: Backend.chat.partial + [#"{"choices":[{"delta":{"refusal":"Cannot answer"}}]}"#], strict: true, error: CancellationError())
        #expect(errors(events).count == 1)
        #expect(errors(events).first.map { if case .providerError("refusal", _) = $0 { true } else { false } } == true)
    }

    @Test func strictToolTerminationRequiresACompleteCall() throws {
        let completeCall = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","function":{"name":"annotate","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#
        let events = try reduce(.chat, frames: [completeCall])
        #expect(errors(events).isEmpty)
        #expect(events.contains { if case .toolUse = $0 { true } else { false } })
        for frame in [
            #"{"choices":[{"finish_reason":"tool_calls"}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{"}}]},"finish_reason":"tool_calls"}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","function":{"name":"annotate","arguments":"{"}}]},"finish_reason":"tool_calls"}]}"#,
        ] {
            #expect(errors(try reduce(.chat, frames: [frame])).count == 1)
        }
    }

    @Test func anthropicNeedsBothAcceptableStopReasonAndMessageStop() throws {
        for reason in ["end_turn", "stop_sequence", "tool_use"] {
            let reasonFrame = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(reason)\"}}"
            #expect(errors(try reduce(.anthropic, frames: Backend.anthropic.partial + [reasonFrame])).count == 1)
            #expect(errors(try reduce(.anthropic, frames: Backend.anthropic.partial + [reasonFrame, #"{"type":"message_stop"}"#])).isEmpty)
        }
        #expect(errors(try reduce(.anthropic, frames: Backend.anthropic.partial + [#"{"type":"message_stop"}"#])).count == 1)
    }
}
