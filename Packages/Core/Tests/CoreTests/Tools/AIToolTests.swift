import Testing
@testable import Core

/// Tests for `AITool`, `AIToolParameter`, and the `AIToolCategory` /
/// `ParameterType` enums.
@Suite("AITool")
struct AIToolTests {
    @Test func initStoresAllFields() {
        let tool = AITool(
            id: "todo.create",
            name: "create",
            description: "Create a task",
            category: .mutation,
            parameters: [
                AIToolParameter(name: "title", type: .string, description: "Title", isRequired: true),
                AIToolParameter(name: "priority", type: .string, description: "Priority", enumValues: ["low", "high"]),
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
        let parameter = AIToolParameter(name: "x", type: .integer, description: "")
        #expect(parameter.isRequired == false)
        #expect(parameter.enumValues == nil)
    }

    @Test func categoriesAreExhaustive() {
        #expect(AIToolCategory.allCases.count == 4)
    }

    @Test func parameterTypesAreExhaustive() {
        #expect(ParameterType.allCases.count == 6)
    }
}
