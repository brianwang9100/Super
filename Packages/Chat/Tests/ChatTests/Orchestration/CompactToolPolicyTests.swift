import Core
import Testing
@testable import Chat

/// Verifies the compact-tier tool filter: small-window models drop the
/// heaviest/lowest-value tools while keeping the grounding + memory set, and
/// large-window models keep everything.
@Suite("CompactToolPolicy")
struct CompactToolPolicyTests {
    private func tool(_ name: String) -> LLMTool {
        LLMTool(
            id: name,
            name: name,
            description: "desc for \(name)",
            category: .query,
            parameters: [],
            appletId: "test"
        )
    }

    /// The full SuperBible-on-AFM tool set, in registry sort order.
    private var allTools: [LLMTool] {
        ["bible.annotate", "bible.note", "bible.read", "bible.search", "memory", "time.now"].map(tool)
    }

    @Test("compact tier drops time.now + bible.annotate + bible.note, keeps grounding + memory")
    func compactDropsHeavyTools() {
        let kept = CompactToolPolicy.filter(allTools, tier: .compact).map(\.name)
        #expect(kept == ["bible.read", "bible.search", "memory"])
        for dropped in CompactToolPolicy.droppedToolNames {
            #expect(!kept.contains(dropped))
        }
    }

    @Test("full tier keeps every tool unchanged")
    func fullKeepsEverything() {
        let kept = CompactToolPolicy.filter(allTools, tier: .full)
        #expect(kept.map(\.name) == allTools.map(\.name))
    }

    @Test("filtering is a no-op when no dropped tools are present")
    func noOpWhenNothingToDrop() {
        let grounding = ["bible.read", "bible.search"].map(tool)
        #expect(CompactToolPolicy.filter(grounding, tier: .compact).map(\.name) == ["bible.read", "bible.search"])
    }

    @Test("compact tier swaps in compactDescription; full tier keeps the full text")
    func compactSwapsDescription() {
        let withCompact = LLMTool(
            id: "bible.read",
            name: "bible.read",
            description: "the long, example-laden full prompt",
            category: .query,
            parameters: [],
            appletId: "bible",
            compactDescription: "the lean prompt"
        )
        let compact = CompactToolPolicy.filter([withCompact], tier: .compact)
        #expect(compact.first?.description == "the lean prompt")
        let full = CompactToolPolicy.filter([withCompact], tier: .full)
        #expect(full.first?.description == "the long, example-laden full prompt")
    }

    @Test("compact swap preserves identity, schema, and labels; nil compactDescription passes through")
    func compactSwapPreservesEverythingElse() {
        let parameters = [
            LLMToolParameter(name: "query", type: .string, description: "q", isRequired: true),
        ]
        let withCompact = LLMTool(
            id: "bible.search",
            name: "bible.search",
            description: "full",
            category: .query,
            parameters: parameters,
            appletId: "bible",
            displayName: "Search scripture",
            summary: "Finds verses.",
            compactDescription: "lean"
        )
        let withoutCompact = tool("memory")
        let result = CompactToolPolicy.filter([withCompact, withoutCompact], tier: .compact)
        let swapped = result[0]
        #expect(swapped.id == "bible.search")
        #expect(swapped.parameters == parameters)
        #expect(swapped.displayName == "Search scripture")
        #expect(swapped.summary == "Finds verses.")
        // No compact variant authored → the tool ships unchanged.
        #expect(result[1] == withoutCompact)
        #expect(result[1].description == "desc for memory")
    }
}
