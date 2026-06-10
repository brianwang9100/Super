import Core
import Testing
@testable import Chat

/// Tests that `SuggestionCapabilities.compact` produces small, schema-free
/// capability lines — never the large LLM-facing `description` or the parameter
/// schema, which would blow AFM's tiny context window.
@Suite("SuggestionCapabilities")
struct SuggestionCapabilitiesTests {
    @Test("uses displayName + summary, never the LLM description or parameter schema")
    func compactFormat() {
        let tools = [
            LLMTool(
                id: "bible.search",
                name: "bible_search",
                description: "LLM_PROMPT_TEXT: huge instruction the model sees, never for the UI…",
                category: .query,
                parameters: [LLMToolParameter(name: "SCHEMA_QUERY_PARAM", type: .string, description: "…")],
                appletId: "bible",
                displayName: "Bible search",
                summary: "Search the Bible by keyword"
            ),
        ]
        let compact = SuggestionCapabilities.compact(from: tools)
        #expect(compact == ["Bible search: Search the Bible by keyword"])
        let joined = compact.joined()
        #expect(!joined.contains("LLM_PROMPT_TEXT"))
        #expect(!joined.contains("SCHEMA_QUERY_PARAM"))
    }

    @Test("falls back to name when the tool has no summary")
    func noSummaryUsesName() {
        let tools = [
            LLMTool(id: "t", name: "do_thing", description: "x", category: .system,
                    parameters: [], appletId: "a", displayName: nil, summary: nil),
        ]
        #expect(SuggestionCapabilities.compact(from: tools) == ["do_thing"])
    }

    @Test("caps to the limit, preserving order")
    func capsToLimit() {
        let tools = (0..<10).map {
            LLMTool(id: "t\($0)", name: "n\($0)", description: "d", category: .query,
                    parameters: [], appletId: "a", displayName: nil, summary: nil)
        }
        #expect(SuggestionCapabilities.compact(from: tools, limit: 4) == ["n0", "n1", "n2", "n3"])
    }

    @Test("empty input returns empty")
    func emptyInput() {
        #expect(SuggestionCapabilities.compact(from: []).isEmpty)
    }
}
