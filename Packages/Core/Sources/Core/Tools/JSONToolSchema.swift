import Foundation

/// Shared HTTP-adapter schema; the AFM GenerationSchema builder has a separate mapping.
public enum JSONToolSchema {
    public static func parametersObject(for parameters: [LLMToolParameter]) -> JSONValue {
        objectSchema(properties: parameters)
    }

    // Omit an empty required list because some local OpenAI shims reject required: [].
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
            // Gemini rejects arrays without items. Assert misconfiguration in debug and
            // fall back to string items in release.
            guard let valueSchema else {
                assertionFailure(
                    "array parameter '\(parameterName)' has no valueSchema; emitting string items"
                )
                fields["items"] = .object(["type": .string("string")])
                break
            }
            fields["items"] = schema(for: valueSchema)
        case .object:
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

    public static func jsonSchemaType(for parameterType: ParameterType) -> String {
        switch parameterType {
        case .bool: return "boolean"
        case .string, .integer, .number, .array, .object: return parameterType.rawValue
        }
    }
}
