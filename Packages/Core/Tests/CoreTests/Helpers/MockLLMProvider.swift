import Foundation
@testable import Core

/// LLM (Large Language Model) provider double for tests. Replays a fixed
/// list of `LLMStreamEvent`s and ignores the request payload.
struct MockLLMProvider: LLMProvider {
    let id: String
    let displayName: String
    let supportedModels: [LLMModel]
    let events: [LLMStreamEvent]

    init(
        id: String,
        displayName: String? = nil,
        supportedModels: [LLMModel] = [],
        events: [LLMStreamEvent] = []
    ) {
        self.id = id
        self.displayName = displayName ?? id
        self.supportedModels = supportedModels
        self.events = events
    }

    func stream(
        messages: [LLMMessage],
        model: LLMModel,
        tools: [LLMTool],
        temperature: Double
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let events = self.events
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}
