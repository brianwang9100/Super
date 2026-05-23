import FoundationModels
import Foundation

/// Apple Foundation Models (AFM) `Tool` conformer that wraps one
/// registered `LLMTool` + the shared `ToolRegistry`. The `LanguageSession`
/// receives an array of these at init time; AFM picks which to invoke and
/// calls `call(arguments:)` in-band during `streamResponse`, splicing the
/// returned string back into the model's context. The provider sees only
/// the model's downstream text snapshots — tool calls are invisible to
/// the outer `LLMStreamEvent` stream.
///
/// `Arguments = GeneratedContent` so a single conformer covers every
/// registered `LLMTool` regardless of schema shape — no per-tool
/// `@Generable` codegen required. Argument extraction maps each declared
/// `LLMToolParameter` to a typed read via
/// `GeneratedContent.value(_:forProperty:)`.
///
/// On executor failure the wrapper returns the error string as the tool
/// output instead of throwing — AFM treats a thrown `ToolCallError` as a
/// generation failure that propagates back as `GenerationError.refusal`,
/// which would surface as a top-level stream error. Returning a string
/// lets the model recover ("the tool failed; I'll explain instead") and
/// matches the in-tree convention from `TimeNowTool` (which returns
/// `isError: true` results rather than throwing).
struct DynamicLLMTool: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let llmTool: LLMTool
    let registry: ToolRegistry
    let parameters: GenerationSchema

    var name: String { llmTool.name }
    var description: String { llmTool.description }

    init(llmTool: LLMTool, registry: ToolRegistry) throws {
        self.llmTool = llmTool
        self.registry = registry
        self.parameters = try DynamicGenerationSchemaBuilder.build(for: llmTool)
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let input = extractInput(from: arguments)
        do {
            let result = try await registry.execute(toolID: llmTool.id, input: input)
            return result.content
        } catch let error as ToolRegistryError {
            return errorOutput(for: error)
        } catch {
            return "tool \(llmTool.id) failed: \(error.localizedDescription)"
        }
    }

    /// Pull each declared parameter out of the AFM-supplied
    /// `GeneratedContent` into the registry's `[String: JSONValue]`
    /// shape. Missing or unreadable values are skipped silently — the
    /// registry's executor is the right place to enforce required-field
    /// semantics, mirroring how the OpenAI path handles malformed
    /// `arguments` JSON.
    private func extractInput(from content: GeneratedContent) -> [String: JSONValue] {
        var input: [String: JSONValue] = [:]
        for parameter in llmTool.parameters {
            if let value = readValue(for: parameter, from: content) {
                input[parameter.name] = value
            }
        }
        return input
    }

    private func readValue(for parameter: LLMToolParameter, from content: GeneratedContent) -> JSONValue? {
        switch parameter.type {
        case .string:
            guard let value = try? content.value(String.self, forProperty: parameter.name) else { return nil }
            return .string(value)
        case .integer:
            guard let value = try? content.value(Int.self, forProperty: parameter.name) else { return nil }
            return .int(value)
        case .number:
            guard let value = try? content.value(Double.self, forProperty: parameter.name) else { return nil }
            return .double(value)
        case .bool:
            guard let value = try? content.value(Bool.self, forProperty: parameter.name) else { return nil }
            return .bool(value)
        case .array:
            guard let value = try? content.value([String].self, forProperty: parameter.name) else { return nil }
            return .array(value.map(JSONValue.string))
        case .object:
            // Object parameters arrive as a JSON string (per the
            // schema builder's fallback); the executor parses if it
            // wants structure.
            guard let value = try? content.value(String.self, forProperty: parameter.name) else { return nil }
            return .string(value)
        }
    }

    private func errorOutput(for error: ToolRegistryError) -> String {
        switch error {
        case .unknownTool(let id):
            return "tool \(id) is not registered"
        case .toolDisabled(let id):
            return "tool \(id) is disabled"
        case .remoteExecutionNotConfigured(let id, _):
            return "tool \(id) has no remote executor configured"
        }
    }
}
