import Testing
import Foundation
@testable import Core

/// Tests for `ToolRegistry` registration, enable / disable, lookup, local
/// dispatch, and `ToolEnablementRepository` integration.
@Suite("ToolRegistry")
struct ToolRegistryTests {
    private func makeTool(id: String = "x.test", appletId: String = "x") -> LLMTool {
        LLMTool(
            id: id,
            name: id,
            description: "",
            category: .query,
            parameters: [],
            appletId: appletId
        )
    }

    @Test func registerStoresRegistration() async {
        let registry = ToolRegistry()
        let tool = makeTool()
        let executor = MockToolExecutor(toolID: tool.id, result: .init(toolID: tool.id, content: "ok"))
        await registry.register(ToolRegistration(tool: tool, execution: .local(executor)))
        let registration = await registry.registration(toolID: tool.id)
        #expect(registration?.tool.id == tool.id)
        #expect(registration?.isEnabled == true)
    }

    @Test func enabledToolsReturnsOnlyEnabled() async throws {
        let registry = ToolRegistry()
        let executor = MockToolExecutor(toolID: "a", result: .init(toolID: "a", content: ""))
        await registry.register(ToolRegistration(tool: makeTool(id: "a"), execution: .local(executor)))
        await registry.register(ToolRegistration(tool: makeTool(id: "b"), execution: .local(executor)))
        try await registry.setEnabled(toolID: "b", enabled: false)
        let enabled = await registry.enabledTools().map(\.id)
        #expect(enabled == ["a"])
    }

    @Test func setEnabledThrowsForUnknown() async {
        let registry = ToolRegistry()
        await #expect(throws: ToolRegistryError.unknownTool("missing")) {
            try await registry.setEnabled(toolID: "missing", enabled: true)
        }
    }

    @Test func executeRoutesToLocalExecutor() async throws {
        let registry = ToolRegistry()
        let expected = ToolResult(toolID: "x.test", content: "result", artifacts: [.init(type: "x", id: "1")])
        let executor = MockToolExecutor(toolID: "x.test", result: expected)
        await registry.register(ToolRegistration(tool: makeTool(), execution: .local(executor)))
        let result = try await registry.execute(toolID: "x.test", input: ["k": .string("v")])
        #expect(result == expected)
        #expect(executor.invocationCount == 1)
        #expect(executor.lastInput == ["k": .string("v")])
    }

    @Test func executeThrowsForDisabledTool() async throws {
        let registry = ToolRegistry()
        let executor = MockToolExecutor(toolID: "x.test", result: .init(toolID: "x.test", content: ""))
        await registry.register(ToolRegistration(tool: makeTool(), execution: .local(executor)))
        try await registry.setEnabled(toolID: "x.test", enabled: false)
        await #expect(throws: ToolRegistryError.toolDisabled("x.test")) {
            _ = try await registry.execute(toolID: "x.test", input: [:])
        }
    }

    @Test func executeThrowsForUnknownTool() async {
        let registry = ToolRegistry()
        await #expect(throws: ToolRegistryError.unknownTool("missing")) {
            _ = try await registry.execute(toolID: "missing", input: [:])
        }
    }

    @Test func executeThrowsForRemoteExecutionInRegistry() async {
        let registry = ToolRegistry()
        let endpoint = RemoteToolEndpoint(url: URL(string: "https://example.test/tool")!)
        await registry.register(ToolRegistration(tool: makeTool(), execution: .remote(endpoint)))
        var caught: Error?
        do {
            _ = try await registry.execute(toolID: "x.test", input: [:])
        } catch {
            caught = error
        }
        if case .remoteExecutionNotConfigured(let id, _) = caught as? ToolRegistryError {
            #expect(id == "x.test")
        } else {
            Issue.record("Expected remoteExecutionNotConfigured, got \(String(describing: caught))")
        }
    }

    @Test func enablementRepositoryPopulatesInitialState() async {
        let store = InMemoryToolEnablementRepository(initial: ["x.test": false])
        let registry = ToolRegistry(enablementRepository: store)
        let executor = MockToolExecutor(toolID: "x.test", result: .init(toolID: "x.test", content: ""))
        await registry.register(ToolRegistration(tool: makeTool(), execution: .local(executor)))
        let registration = await registry.registration(toolID: "x.test")
        #expect(registration?.isEnabled == false)
    }

    @Test func setEnabledPersistsToStore() async throws {
        let store = InMemoryToolEnablementRepository()
        let registry = ToolRegistry(enablementRepository: store)
        let executor = MockToolExecutor(toolID: "x.test", result: .init(toolID: "x.test", content: ""))
        await registry.register(ToolRegistration(tool: makeTool(), execution: .local(executor)))
        try await registry.setEnabled(toolID: "x.test", enabled: false)
        #expect(store.snapshot["x.test"] == false)
    }

    @Test func enabledToolsForProviderReturnsAllEnabled() async {
        let registry = ToolRegistry()
        let executor = MockToolExecutor(toolID: "a", result: .init(toolID: "a", content: ""))
        await registry.register(ToolRegistration(tool: makeTool(id: "a"), execution: .local(executor)))
        let provider = MockLLMProvider(id: "openai")
        let tools = await registry.enabledTools(for: provider)
        #expect(tools.map(\.id) == ["a"])
    }
}
