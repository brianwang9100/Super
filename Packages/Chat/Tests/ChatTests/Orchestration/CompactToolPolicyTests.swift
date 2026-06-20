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
        ["bible.annotate", "bible.highlight", "bible.lookup", "bible.note", "memory", "time.now"].map(tool)
    }

    @Test("compact tier drops time.now + bible write tools, keeps grounding + memory")
    func compactDropsHeavyTools() {
        let kept = CompactToolPolicy.filter(allTools, tier: .compact).map(\.name)
        #expect(kept == ["bible.lookup", "memory"])
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
        let grounding = ["bible.lookup", "memory"].map(tool)
        #expect(CompactToolPolicy.filter(grounding, tier: .compact).map(\.name) == ["bible.lookup", "memory"])
    }

    @Test("compact tier swaps in compactDescription; full tier keeps the full text")
    func compactSwapsDescription() {
        let withCompact = LLMTool(
            id: "bible.lookup",
            name: "bible.lookup",
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

    @Test("compact swap preserves identity and labels; nil compactDescription passes through")
    func compactSwapPreservesEverythingElse() {
        let parameters = [
            LLMToolParameter(name: "query", type: .string, description: "q", isRequired: true),
        ]
        let withCompact = LLMTool(
            id: "bible.lookup",
            name: "bible.lookup",
            description: "full",
            category: .query,
            parameters: parameters,
            appletId: "bible",
            displayName: "Look up scripture",
            summary: "Reads or searches.",
            compactDescription: "lean"
        )
        let withoutCompact = tool("memory")
        let result = CompactToolPolicy.filter([withCompact, withoutCompact], tier: .compact)
        let swapped = result[0]
        #expect(swapped.id == "bible.lookup")
        // A param with no compactDescription passes through unchanged.
        #expect(swapped.parameters == parameters)
        #expect(swapped.displayName == "Look up scripture")
        #expect(swapped.summary == "Reads or searches.")
        // No compact variant authored → the tool ships unchanged.
        #expect(result[1] == withoutCompact)
        #expect(result[1].description == "desc for memory")
    }

    @Test("compact tier swaps each parameter's compactDescription, leaving schema fields intact")
    func compactSwapsParameterDescriptions() {
        let verboseEnum = LLMToolParameter(
            name: "match",
            type: .string,
            description: "long enum prose explaining any/all/phrase at length",
            isRequired: false,
            enumValues: ["any", "all", "phrase"],
            compactDescription: "any/all/phrase"
        )
        let plain = LLMToolParameter(name: "query", type: .string, description: "q", isRequired: true)
        let tool = LLMTool(
            id: "bible.lookup",
            name: "bible.lookup",
            description: "full",
            category: .query,
            parameters: [verboseEnum, plain],
            appletId: "bible",
            compactDescription: "lean"
        )

        let compact = CompactToolPolicy.filter([tool], tier: .compact).first
        let compactMatch = compact?.parameters.first { $0.name == "match" }
        // Description shrinks…
        #expect(compactMatch?.description == "any/all/phrase")
        // …but every schema-shaping field is preserved, so validation is unaffected.
        #expect(compactMatch?.enumValues == ["any", "all", "phrase"])
        #expect(compactMatch?.isRequired == false)
        // A param with no compactDescription is left untouched.
        #expect(compact?.parameters.first { $0.name == "query" }?.description == "q")

        // Full tier keeps the verbose parameter description.
        let full = CompactToolPolicy.filter([tool], tier: .full).first
        #expect(full?.parameters.first { $0.name == "match" }?.description == "long enum prose explaining any/all/phrase at length")
    }
}
