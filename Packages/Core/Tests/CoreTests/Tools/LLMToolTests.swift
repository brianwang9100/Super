import Testing
@testable import Core

/// Tests for `LLMTool`, `LLMToolParameter`, and the `LLMToolCategory` /
/// `ParameterType` enums.
@Suite("LLMTool")
struct LLMToolTests {
    @Test func initStoresAllFields() {
        let tool = LLMTool(
            id: "todo.create",
            name: "create",
            description: "Create a task",
            category: .mutation,
            parameters: [
                LLMToolParameter(name: "title", type: .string, description: "Title", isRequired: true),
                LLMToolParameter(name: "priority", type: .string, description: "Priority", enumValues: ["low", "high"]),
            ],
            appletId: "todo"
        )
        #expect(tool.id == "todo.create")
        #expect(tool.category == .mutation)
        #expect(tool.parameters.count == 2)
        #expect(tool.parameters[0].isRequired)
        #expect(tool.parameters[1].enumValues == ["low", "high"])
        #expect(tool.appletId == "todo")
    }

    @Test func parameterDefaults() {
        let parameter = LLMToolParameter(name: "x", type: .integer, description: "")
        #expect(parameter.isRequired == false)
        #expect(parameter.enumValues == nil)
    }

    @Test func categoriesAreExhaustive() {
        #expect(LLMToolCategory.allCases.count == 4)
    }

    @Test func parameterTypesAreExhaustive() {
        #expect(ParameterType.allCases.count == 6)
    }
}
