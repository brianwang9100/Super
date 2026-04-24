import Testing
import Foundation
@testable import Core

/// Tests for `ToolDefinition`'s default enablement, copy-on-toggle, and
/// `.local` / `.remote` execution variants.
@Suite("ToolDefinition")
struct ToolDefinitionTests {
    private func makeTool() -> AITool {
        AITool(
            id: "x.test",
            name: "test",
            description: "A test tool",
            category: .query,
            parameters: [],
            appletId: "x"
        )
    }

    @Test func defaultIsEnabled() {
        let executor = MockToolExecutor(toolID: "x.test", result: .init(toolID: "x.test", content: ""))
        let definition = ToolDefinition(tool: makeTool(), execution: .local(executor))
        #expect(definition.isEnabled)
    }

    @Test func enabledHelperReturnsModifiedCopy() {
        let executor = MockToolExecutor(toolID: "x.test", result: .init(toolID: "x.test", content: ""))
        let original = ToolDefinition(tool: makeTool(), execution: .local(executor), isEnabled: true)
        let disabled = original.enabled(false)
        #expect(original.isEnabled)
        #expect(!disabled.isEnabled)
        #expect(disabled.tool.id == original.tool.id)
    }

    @Test func remoteExecutionStoresEndpoint() {
        let endpoint = RemoteToolEndpoint(url: URL(string: "https://example.test/tool")!)
        let definition = ToolDefinition(tool: makeTool(), execution: .remote(endpoint))
        if case .remote(let stored) = definition.execution {
            #expect(stored.url == endpoint.url)
        } else {
            Issue.record("Expected .remote execution")
        }
    }
}
