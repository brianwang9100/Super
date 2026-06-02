import Core
import Foundation
import Testing

@testable import Chat

/// Unit coverage for `NativeWebSearch` — the shared sentinel/proposal
/// convention the cost gate and the native adapters key off. Pure logic, no
/// provider or network.
@Suite("NativeWebSearch")
struct NativeWebSearchTests {

    private func tool(_ name: String) -> LLMTool {
        LLMTool(id: name, name: name, description: "", category: .query, parameters: [], appletId: "test")
    }

    @Test("usesNativeSearch is true only for the native backend value")
    func usesNativeSearch() {
        func model(_ backend: String?) -> LLMModel {
            LLMModel(id: "m", displayName: "M", searchBackend: backend)
        }
        #expect(NativeWebSearch.usesNativeSearch(model("native")))
        #expect(!NativeWebSearch.usesNativeSearch(model(nil)))
        #expect(!NativeWebSearch.usesNativeSearch(model("tavily")))
    }

    @Test("partition strips the sentinel and flags search enabled")
    func partitionStripsSentinel() {
        let (clientTools, enabled) = NativeWebSearch.partition([
            tool("alpha"),
            NativeWebSearch.sentinelTool,
            tool("beta")
        ])
        #expect(enabled)
        #expect(clientTools.map(\.name) == ["alpha", "beta"])
    }

    @Test("partition keeps the proposal tool as a normal client tool")
    func partitionKeepsProposal() {
        // The proposal tool is a real function the model sees — only the
        // sentinel is stripped. A turn while the gate is ON carries the
        // proposal (no sentinel), so `searchEnabled` must be false.
        let (clientTools, enabled) = NativeWebSearch.partition([
            tool("alpha"),
            NativeWebSearch.proposalTool
        ])
        #expect(!enabled)
        #expect(clientTools.map(\.name) == ["alpha", NativeWebSearch.proposalToolName])
    }

    @Test("partition reports no search when neither token is present")
    func partitionNoSearch() {
        let (clientTools, enabled) = NativeWebSearch.partition([tool("alpha")])
        #expect(!enabled)
        #expect(clientTools.count == 1)
    }

    @Test("proposal tool declares query + reason as required string params")
    func proposalSchema() {
        let params = NativeWebSearch.proposalTool.parameters
        #expect(params.count == 2)
        let query = params.first { $0.name == NativeWebSearch.proposalQueryParameter }
        let reason = params.first { $0.name == NativeWebSearch.proposalReasonParameter }
        #expect(query?.isRequired == true)
        #expect(query?.type == .string)
        #expect(reason?.isRequired == true)
        #expect(reason?.type == .string)
    }

    @Test("proposed query + reason parse out of the stored parameters JSON")
    func parsesProposedFields() throws {
        let json = try ToolCallRecord.encode(.object([
            "query": .string("mars rover latest news"),
            "reason": .string("current events beyond training")
        ]))
        #expect(NativeWebSearch.proposedQuery(fromParametersJSON: json) == "mars rover latest news")
        #expect(NativeWebSearch.proposedReason(fromParametersJSON: json) == "current events beyond training")
    }

    @Test("missing or malformed parameters yield empty strings, never a crash")
    func parsesMissingFields() {
        #expect(NativeWebSearch.proposedQuery(fromParametersJSON: "{}") == "")
        #expect(NativeWebSearch.proposedReason(fromParametersJSON: "not json") == "")
        #expect(NativeWebSearch.proposedQuery(fromParametersJSON: "") == "")
    }
}
