import Testing
@testable import Core

/// Tests for `JSONToolSchema` — the shared builder that renders
/// `[LLMToolParameter]` into the JSON-Schema `parameters` object every HTTP LLM
/// adapter sends. The load-bearing case is `items` on `.array` parameters,
/// whose omission makes the native Gemini adapter reject the tool declaration
/// with HTTP 400 (`parameters.properties[entries].items: missing field`).
@Suite("JSONToolSchema")
struct JSONToolSchemaTests {
    private func object(_ value: JSONValue?) -> [String: JSONValue] {
        guard case .object(let dict)? = value else {
            Issue.record("expected .object, got \(String(describing: value))")
            return [:]
        }
        return dict
    }

    private func properties(of schema: JSONValue) -> [String: JSONValue] {
        object(object(schema)["properties"])
    }

    @Test func emitsObjectWithPropertiesAndRequired() {
        let schema = JSONToolSchema.parametersObject(for: [
            LLMToolParameter(name: "a", type: .string, description: "A", isRequired: true),
            LLMToolParameter(name: "b", type: .integer, description: "B"),
        ])
        let top = object(schema)
        #expect(top["type"] == .string("object"))
        #expect(top["required"] == .array([.string("a")]))
        let props = properties(of: schema)
        #expect(object(props["a"])["type"] == .string("string"))
        #expect(object(props["b"])["type"] == .string("integer"))
    }

    @Test func omitsRequiredWhenEmpty() {
        let schema = JSONToolSchema.parametersObject(for: [
            LLMToolParameter(name: "a", type: .string, description: "A"),
        ])
        #expect(object(schema)["required"] == nil)
    }

    @Test func mapsBoolToBoolean() {
        let schema = JSONToolSchema.parametersObject(for: [
            LLMToolParameter(name: "flag", type: .bool, description: "F"),
        ])
        #expect(object(properties(of: schema)["flag"])["type"] == .string("boolean"))
    }

    @Test func emitsEnumForConstrainedScalar() {
        let schema = JSONToolSchema.parametersObject(for: [
            LLMToolParameter(name: "op", type: .string, description: "Op", enumValues: ["a", "b"]),
        ])
        #expect(object(properties(of: schema)["op"])["enum"] == .array([.string("a"), .string("b")]))
    }

    @Test func arrayOfObjectsEmitsItemsWithNestedProperties() {
        let schema = JSONToolSchema.parametersObject(for: [
            LLMToolParameter(
                name: "entries", type: .array, description: "cards", isRequired: true,
                valueSchema: .object([
                    LLMToolParameter(name: "category", type: .string, description: "c",
                                     isRequired: true, enumValues: ["author", "summary"]),
                    LLMToolParameter(name: "title", type: .string, description: "t", isRequired: true),
                ])
            ),
        ])
        let entries = object(properties(of: schema)["entries"])
        #expect(entries["type"] == .string("array"))
        let items = object(entries["items"])
        #expect(items["type"] == .string("object"))
        #expect(items["required"] == .array([.string("category"), .string("title")]))
        let itemProps = object(items["properties"])
        #expect(object(itemProps["category"])["enum"] == .array([.string("author"), .string("summary")]))
        #expect(object(itemProps["title"])["type"] == .string("string"))
    }

    @Test func arrayOfScalarsEmitsScalarItems() {
        let schema = JSONToolSchema.parametersObject(for: [
            LLMToolParameter(name: "tags", type: .array, description: "tags",
                             valueSchema: .scalar(.string)),
        ])
        let tags = object(properties(of: schema)["tags"])
        #expect(tags["type"] == .string("array"))
        #expect(object(tags["items"])["type"] == .string("string"))
    }

    @Test func nestedArrayOfArrays() {
        let schema = JSONToolSchema.parametersObject(for: [
            LLMToolParameter(name: "matrix", type: .array, description: "m",
                             valueSchema: .array(element: .scalar(.integer))),
        ])
        let matrix = object(properties(of: schema)["matrix"])
        let outerItems = object(matrix["items"])
        #expect(outerItems["type"] == .string("array"))
        #expect(object(outerItems["items"])["type"] == .string("integer"))
    }
}
