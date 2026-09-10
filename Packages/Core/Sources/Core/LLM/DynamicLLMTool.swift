import FoundationModels
import Foundation

/// AFM invokes this in-band, outside the outer tool-event stream. Return executor
/// errors as tool output: throwing would turn a recoverable tool failure into
/// a top-level generation refusal.
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

    // Skip unreadable/missing arguments; the executor owns required-field validation.
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
            // The schema builder exposes objects as JSON strings for executor-side parsing.
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
