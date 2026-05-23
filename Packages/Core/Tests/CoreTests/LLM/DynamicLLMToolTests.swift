import FoundationModels
import Foundation
import Testing
import os
@testable import Core

/// Tests for `DynamicLLMTool`'s parameter extraction and registry dispatch,
/// and for `DynamicGenerationSchemaBuilder`'s mapping from `LLMTool`
/// parameter descriptors to `DynamicGenerationSchema`. These don't
/// exercise Apple Foundation Models (AFM) at all — the tool is unit-
/// tested in isolation against a real `ToolRegistry`.
@Suite
struct DynamicLLMToolTests {

    @Test
    func callDispatchesToRegistryAndReturnsResultContent() async throws {
        let executor = ScriptedToolExecutor(toolID: "echo", content: "echo: hello")
        let registry = await makeRegistry(toolID: "echo", executor: executor, parameters: [])
        let dynamicTool = try DynamicLLMTool(
            llmTool: descriptor(toolID: "echo", parameters: []),
            registry: registry
        )

        let result = try await dynamicTool.call(arguments: emptyArguments())

        #expect(result == "echo: hello")
        let captured = await executor.lastInput
        #expect(captured?.isEmpty == true)
    }

    @Test
    func callExtractsRequiredStringParameter() async throws {
        let executor = ScriptedToolExecutor(toolID: "echo", content: "ok")
        let parameter = LLMToolParameter(
            name: "message",
            type: .string,
            description: "text to echo",
            isRequired: true
        )
        let registry = await makeRegistry(toolID: "echo", executor: executor, parameters: [parameter])
        let dynamicTool = try DynamicLLMTool(
            llmTool: descriptor(toolID: "echo", parameters: [parameter]),
            registry: registry
        )

        _ = try await dynamicTool.call(arguments: GeneratedContent(properties: [
            "message": "hello"
        ]))

        let captured = await executor.lastInput
        #expect(captured == ["message": .string("hello")])
    }

    @Test
    func callExtractsIntegerNumberAndBoolParameters() async throws {
        let executor = ScriptedToolExecutor(toolID: "math", content: "ok")
        let parameters: [LLMToolParameter] = [
            .init(name: "count", type: .integer, description: "", isRequired: true),
            .init(name: "ratio", type: .number, description: "", isRequired: true),
            .init(name: "loud", type: .bool, description: "", isRequired: true),
        ]
        let registry = await makeRegistry(toolID: "math", executor: executor, parameters: parameters)
        let dynamicTool = try DynamicLLMTool(
            llmTool: descriptor(toolID: "math", parameters: parameters),
            registry: registry
        )

        _ = try await dynamicTool.call(arguments: GeneratedContent(properties: [
            "count": 5,
            "ratio": 0.5,
            "loud": true,
        ]))

        let captured = await executor.lastInput
        #expect(captured?["count"] == .int(5))
        #expect(captured?["ratio"] == .double(0.5))
        #expect(captured?["loud"] == .bool(true))
    }

    @Test
    func callOmitsParameterAbsentFromArguments() async throws {
        let executor = ScriptedToolExecutor(toolID: "echo", content: "ok")
        let parameter = LLMToolParameter(
            name: "message",
            type: .string,
            description: "",
            isRequired: false
        )
        let registry = await makeRegistry(toolID: "echo", executor: executor, parameters: [parameter])
        let dynamicTool = try DynamicLLMTool(
            llmTool: descriptor(toolID: "echo", parameters: [parameter]),
            registry: registry
        )

        // Pass no properties — AFM does this when the model decides to
        // omit an optional argument.
        _ = try await dynamicTool.call(arguments: emptyArguments())

        let captured = await executor.lastInput
        // Missing parameter is dropped, not surfaced as null/empty.
        #expect(captured?.isEmpty == true)
    }

    @Test
    func callReturnsErrorStringWhenRegistryThrowsToolDisabled() async throws {
        let executor = ScriptedToolExecutor(toolID: "echo", content: "unreached")
        let registry = ToolRegistry()
        await registry.register(ToolRegistration(
            tool: descriptor(toolID: "echo", parameters: []),
            execution: .local(executor),
            isEnabled: false
        ))
        let dynamicTool = try DynamicLLMTool(
            llmTool: descriptor(toolID: "echo", parameters: []),
            registry: registry
        )

        let result = try await dynamicTool.call(arguments: emptyArguments())

        #expect(result == "tool echo is disabled")
    }

    @Test
    func callReturnsErrorStringWhenExecutorThrows() async throws {
        let failingExecutor = FailingToolExecutor(toolID: "boom")
        let registry = await makeRegistry(toolID: "boom", executor: failingExecutor, parameters: [])
        let dynamicTool = try DynamicLLMTool(
            llmTool: descriptor(toolID: "boom", parameters: []),
            registry: registry
        )

        let result = try await dynamicTool.call(arguments: emptyArguments())

        // Non-registry errors surface as a tool-output string that AFM
        // feeds back to the model; the stream is never failed.
        #expect(result.contains("tool boom failed"))
    }

    // MARK: - Schema builder

    @Test
    func schemaForStringParameterUsesStringDynamicSchema() {
        let parameter = LLMToolParameter(
            name: "message", type: .string, description: "text", isRequired: true
        )
        let tool = descriptor(toolID: "t", parameters: [parameter])
        let root = DynamicGenerationSchemaBuilder.root(for: tool)
        #expect(String(describing: root).contains("message"))
    }

    @Test
    func schemaForEnumParameterUsesAnyOfChoices() throws {
        let parameter = LLMToolParameter(
            name: "color", type: .string, description: "",
            isRequired: true, enumValues: ["red", "green", "blue"]
        )
        let tool = descriptor(toolID: "t", parameters: [parameter])
        // GenerationSchema is opaque once constructed — round-trip
        // through `init(root:dependencies:)` is the smoke test that
        // the anyOf-overloaded `DynamicGenerationSchema.init` was
        // selected rather than the type-based one (which would refuse
        // a String + enum mix).
        _ = try DynamicGenerationSchemaBuilder.build(for: tool)
    }

    @Test(arguments: ParameterType.allCases)
    func schemaBuildsSuccessfullyForEveryParameterType(parameterType: ParameterType) throws {
        let parameter = LLMToolParameter(
            name: "p", type: parameterType, description: "", isRequired: false
        )
        let tool = descriptor(toolID: "t", parameters: [parameter])
        _ = try DynamicGenerationSchemaBuilder.build(for: tool)
    }

    // MARK: - Helpers

    private func descriptor(toolID: String, parameters: [LLMToolParameter]) -> LLMTool {
        LLMTool(
            id: toolID,
            name: toolID,
            description: "test tool \(toolID)",
            category: .query,
            parameters: parameters,
            appletId: "test"
        )
    }

    private func makeRegistry(
        toolID: String,
        executor: any ToolExecutor,
        parameters: [LLMToolParameter]
    ) async -> ToolRegistry {
        let registry = ToolRegistry()
        await registry.register(ToolRegistration(
            tool: descriptor(toolID: toolID, parameters: parameters),
            execution: .local(executor),
            isEnabled: true
        ))
        return registry
    }

    private func emptyArguments() -> GeneratedContent {
        GeneratedContent(kind: .structure(properties: [:], orderedKeys: []))
    }
}

// MARK: - Test doubles

/// Lock-backed executor that records the last input it received and
/// returns a fixed `ToolResult`. Used to assert that
/// `DynamicLLMTool` projected the AFM arguments into the right
/// `[String: JSONValue]` shape before dispatch.
final class ScriptedToolExecutor: ToolExecutor, Sendable {
    let toolID: String
    private let content: String
    private let storage = OSAllocatedUnfairLock<[String: JSONValue]?>(initialState: nil)

    init(toolID: String, content: String) {
        self.toolID = toolID
        self.content = content
    }

    func execute(input: [String: JSONValue]) async throws -> ToolResult {
        storage.withLock { $0 = input }
        return ToolResult(toolID: toolID, content: content)
    }

    var lastInput: [String: JSONValue]? {
        storage.withLock { $0 }
    }
}

/// Executor that throws a generic error to exercise the
/// `DynamicLLMTool` non-`ToolRegistryError` branch.
struct FailingToolExecutor: ToolExecutor {
    let toolID: String

    struct TestError: Error {}

    func execute(input: [String: JSONValue]) async throws -> ToolResult {
        throw TestError()
    }
}

