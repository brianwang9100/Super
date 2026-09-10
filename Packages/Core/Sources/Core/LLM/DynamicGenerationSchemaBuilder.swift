import FoundationModels

/// This AFM mapping ignores valueSchema: arrays become string arrays and objects JSON strings.
enum DynamicGenerationSchemaBuilder {
    static func build(for tool: LLMTool) throws -> GenerationSchema {
        let root = root(for: tool)
        return try GenerationSchema(root: root, dependencies: [])
    }

    // Keep raw schema construction testable before GenerationSchema makes it opaque.
    static func root(for tool: LLMTool) -> DynamicGenerationSchema {
        let properties = tool.parameters.map { parameter in
            DynamicGenerationSchema.Property(
                name: parameter.name,
                description: parameter.description,
                schema: schema(for: parameter),
                isOptional: !parameter.isRequired
            )
        }
        return DynamicGenerationSchema(
            name: tool.id,
            description: tool.description,
            properties: properties
        )
    }

    private static func schema(for parameter: LLMToolParameter) -> DynamicGenerationSchema {
        if let enumValues = parameter.enumValues, !enumValues.isEmpty {
            return DynamicGenerationSchema(
                name: parameter.name,
                description: parameter.description,
                anyOf: enumValues
            )
        }
        switch parameter.type {
        case .string:
            return DynamicGenerationSchema(type: String.self)
        case .integer:
            return DynamicGenerationSchema(type: Int.self)
        case .number:
            return DynamicGenerationSchema(type: Double.self)
        case .bool:
            return DynamicGenerationSchema(type: Bool.self)
        case .array:
            return DynamicGenerationSchema(
                arrayOf: DynamicGenerationSchema(type: String.self)
            )
        case .object:
            return DynamicGenerationSchema(type: String.self)
        }
    }
}
