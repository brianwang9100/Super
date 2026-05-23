import FoundationModels

/// Builds a `FoundationModels.GenerationSchema` from an `LLMTool`'s
/// declarative `[LLMToolParameter]`. Used by `DynamicLLMTool` so each
/// registered tool exposes a schema to Apple Foundation Models without
/// requiring per-tool `@Generable` codegen.
///
/// The Phase 4 mapping is intentionally narrow: `LLMToolParameter` carries
/// no element type for `.array` and no nested-property layout for
/// `.object`, so those map to "array of strings" and "string" fallbacks
/// respectively. A richer schema model (nested objects, typed array
/// items) is a follow-up — the only built-in tool today (`TimeNowTool`)
/// uses a single optional string parameter and exercises the common case.
enum DynamicGenerationSchemaBuilder {
    static func build(for tool: LLMTool) throws -> GenerationSchema {
        let root = root(for: tool)
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// Build the root `DynamicGenerationSchema` for `tool`. Exposed
    /// internally so tests can assert on the schema before it's wrapped
    /// in `GenerationSchema` (which is opaque once constructed).
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
        // `enumValues` overrides the type-based mapping: AFM enforces the
        // closed choice list via the `anyOf` constructor.
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
            // `LLMToolParameter` carries no element-type info, so we
            // default to `[String]`. Tools that need typed arrays should
            // wait on the richer parameter model.
            return DynamicGenerationSchema(
                arrayOf: DynamicGenerationSchema(type: String.self)
            )
        case .object:
            // No nested-property layout in our parameter model; fall
            // back to a string the tool implementation can parse itself.
            return DynamicGenerationSchema(type: String.self)
        }
    }
}
