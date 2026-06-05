import Foundation

/// Renders an `LLMTool`'s declarative `[LLMToolParameter]` into the JSON-Schema
/// `{ "type": "object", "properties": {…}, "required": […] }` object that every
/// HTTP LLM (Large Language Model) adapter sends as a function/tool parameter
/// schema (OpenAI `parameters`, Anthropic `input_schema`, Gemini `parameters`).
///
/// Centralizing it here is the single place that knows to emit JSON-Schema
/// `items` for an `.array` parameter and nested `properties` for an `.object` —
/// without which the native Gemini `generateContent` validator rejects the tool
/// declaration with HTTP 400 (`parameters.properties[x].items: missing field`).
/// The Apple Foundation path keeps its own `DynamicGenerationSchemaBuilder`
/// (Apple's `GenerationSchema` is a different shape, not JSON Schema).
public enum JSONToolSchema {
    /// The top-level parameters object for a tool's declared parameters.
    public static func parametersObject(for parameters: [LLMToolParameter]) -> JSONValue {
        objectSchema(properties: parameters)
    }

    /// `{ "type": "object", "properties": {…}, "required": […] }` for a set of
    /// named properties. `required` is omitted when empty — some local OpenAI
    /// shims reject `"required": []`, and the spec treats absent and empty as
    /// equivalent.
    private static func objectSchema(properties parameters: [LLMToolParameter]) -> JSONValue {
        var properties: [String: JSONValue] = [:]
        var required: [String] = []
        for parameter in parameters {
            properties[parameter.name] = propertySchema(for: parameter)
            if parameter.isRequired { required.append(parameter.name) }
        }
        var object: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            object["required"] = .array(required.map { .string($0) })
        }
        return .object(object)
    }

    /// One named parameter's schema, carrying its `description` alongside the
    /// type-driven shape (`enum`, `items`, nested `properties`).
    private static func propertySchema(for parameter: LLMToolParameter) -> JSONValue {
        var fields = typeFields(
            type: parameter.type,
            enumValues: parameter.enumValues,
            valueSchema: parameter.valueSchema,
            parameterName: parameter.name
        )
        fields["description"] = .string(parameter.description)
        return .object(fields)
    }

    /// The `{ "type": …, "enum"?, "items"?, "properties"?, "required"? }` fields
    /// for a value of the given `type`, before any `description` is attached.
    private static func typeFields(
        type: ParameterType,
        enumValues: [String]?,
        valueSchema: ToolValueSchema?,
        parameterName: String
    ) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["type": .string(jsonSchemaType(for: type))]
        if let enumValues, !enumValues.isEmpty {
            fields["enum"] = .array(enumValues.map { .string($0) })
        }
        switch type {
        case .array:
            // JSON Schema requires `items`; native Gemini 400s without it. A
            // missing `valueSchema` is a misconfigured tool — assert in debug,
            // and fall back to string items so we never ship an array with no
            // `items`.
            guard let valueSchema else {
                assertionFailure(
                    "array parameter '\(parameterName)' has no valueSchema; emitting string items"
                )
                fields["items"] = .object(["type": .string("string")])
                break
            }
            fields["items"] = schema(for: valueSchema)
        case .object:
            // Merge a nested object's properties/required up onto this schema.
            if case .object(let nestedProperties) = valueSchema,
               case .object(let nested) = objectSchema(properties: nestedProperties) {
                fields["properties"] = nested["properties"] ?? .object([:])
                if let required = nested["required"] { fields["required"] = required }
            }
        default:
            break
        }
        return fields
    }

    /// Recursively render a `ToolValueSchema` into a self-contained schema
    /// object (used for array `items` and nested arrays).
    private static func schema(for valueSchema: ToolValueSchema) -> JSONValue {
        switch valueSchema {
        case .scalar(let type, let enumValues):
            var fields: [String: JSONValue] = ["type": .string(jsonSchemaType(for: type))]
            if let enumValues, !enumValues.isEmpty {
                fields["enum"] = .array(enumValues.map { .string($0) })
            }
            return .object(fields)
        case .object(let properties):
            return objectSchema(properties: properties)
        case .array(let element):
            return .object([
                "type": .string("array"),
                "items": schema(for: element),
            ])
        }
    }

    /// `LLMToolParameter`/`ToolValueSchema` reuse Swift-friendly names (`bool`);
    /// JSON Schema uses `boolean`. Translate at the boundary.
    public static func jsonSchemaType(for parameterType: ParameterType) -> String {
        switch parameterType {
        case .bool: return "boolean"
        case .string, .integer, .number, .array, .object: return parameterType.rawValue
        }
    }
}
