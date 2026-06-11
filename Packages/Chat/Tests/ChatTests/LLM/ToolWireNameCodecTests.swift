import Core
import Foundation
import Testing
@testable import Chat

/// Unit tests for `ToolWireNameCodec` / `ToolWireNameMap` — the wire-level
/// tool-name sanitizer the OpenAI and Anthropic adapters use because those
/// APIs reject Super's dot-namespaced tool IDs (`^[a-zA-Z0-9_-]+$`).
@Suite("ToolWireNameCodec")
struct ToolWireNameCodecTests {
    private func makeTool(name: String) -> LLMTool {
        LLMTool(
            id: name,
            name: name,
            description: "Test tool \(name)",
            category: .query,
            parameters: [],
            appletId: "chat"
        )
    }

    @Test func sanitizedReplacesDisallowedCharactersWithUnderscores() {
        #expect(ToolWireNameCodec.sanitized("time.now") == "time_now")
        #expect(ToolWireNameCodec.sanitized("bible.read") == "bible_read")
        #expect(ToolWireNameCodec.sanitized("a.b.c") == "a_b_c")
        #expect(ToolWireNameCodec.sanitized("spaced name!") == "spaced_name_")
    }

    @Test func sanitizedIsIdentityForAlreadyLegalNames() {
        #expect(ToolWireNameCodec.sanitized("get_weather") == "get_weather")
        #expect(ToolWireNameCodec.sanitized("get-time-2") == "get-time-2")
        #expect(ToolWireNameCodec.sanitized("__native_web_search__") == "__native_web_search__")
    }

    @Test func mapRoundTripsAdvertisedDotNames() {
        let map = ToolWireNameMap(tools: [makeTool(name: "time.now"), makeTool(name: "bible.read")])
        #expect(map.wireName(forOriginal: "time.now") == "time_now")
        #expect(map.wireName(forOriginal: "bible.read") == "bible_read")
        #expect(map.originalName(forWire: "time_now") == "time.now")
        #expect(map.originalName(forWire: "bible_read") == "bible.read")
    }

    @Test func unknownWireNamePassesThroughUnchanged() {
        let map = ToolWireNameMap(tools: [makeTool(name: "time.now")])
        // Server tools or a hallucinated name must not be rewritten.
        #expect(map.originalName(forWire: "web_search") == "web_search")
    }

    @Test func unadvertisedOriginalFallsBackToPureSanitizer() {
        // Replayed history of a since-disabled tool still encodes consistently.
        let map = ToolWireNameMap(tools: [])
        #expect(map.wireName(forOriginal: "todo.create") == "todo_create")
    }

    @Test func collidingSanitizedNamesAreDisambiguatedDeterministically() {
        let map = ToolWireNameMap(tools: [makeTool(name: "a.b"), makeTool(name: "a_b")])
        let first = map.wireName(forOriginal: "a.b")
        let second = map.wireName(forOriginal: "a_b")
        #expect(first != second)
        // Both wire names reverse-map to their own original.
        #expect(map.originalName(forWire: first) == "a.b")
        #expect(map.originalName(forWire: second) == "a_b")
    }

    @Test func restoringToolNameRewritesOnlyToolUseEvents() {
        let map = ToolWireNameMap(tools: [makeTool(name: "time.now")])
        let restored = map.restoringToolName(
            in: .toolUse(index: 0, id: "call_1", name: "time_now", input: .object([:]), signature: nil)
        )
        #expect(restored == .toolUse(index: 0, id: "call_1", name: "time.now", input: .object([:]), signature: nil))
        let text = LLMStreamEvent.textDelta(index: 0, text: "hi")
        #expect(map.restoringToolName(in: text) == text)
    }
}
