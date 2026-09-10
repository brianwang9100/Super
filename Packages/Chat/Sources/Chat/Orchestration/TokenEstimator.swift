import Core
import Foundation

/// Implementations must be deterministic and side-effect-free; estimation runs before each turn.
public protocol TokenEstimator: Sendable {
    /// Empty strings return zero.
    func estimate(_ text: String) -> Int
}

extension TokenEstimator {
    public func estimate(messages: [LLMMessage]) -> Int {
        var total = 0
        for message in messages {
            for block in message.content {
                switch block {
                case .text(let text):
                    total += estimate(text)
                case .thinking(let content, let signature):
                    total += estimate(content)
                    if let signature { total += estimate(signature) }
                case .toolUse(_, let name, let input, _):
                    total += estimate(name)
                    total += estimate(JSONStringifier.string(for: input))
                case .toolResult(_, let content, _):
                    total += estimate(content)
                case .searchResult(let sources):
                    // Encrypted provider echoes cannot be sized here, so this may undercount replayed search context.
                    for source in sources {
                        total += estimate(source.title)
                        if let snippet = source.snippet { total += estimate(snippet) }
                    }
                }
            }
        }
        return total
    }

    /// Include tool definitions separately from messages. Provider-specific schema framing
    /// is omitted, so the estimate can undercount the actual request.
    public func estimate(tools: [LLMTool]) -> Int {
        var total = 0
        for tool in tools {
            total += estimate(tool.name)
            total += estimate(tool.description)
            total += estimate(Self.schemaText(of: tool.parameters))
        }
        return total
    }

    private static func schemaText(of parameters: [LLMToolParameter]) -> String {
        var pieces: [String] = []
        for parameter in parameters {
            pieces.append(parameter.name)
            pieces.append(parameter.type.rawValue)
            pieces.append(parameter.description)
            if let enumValues = parameter.enumValues {
                pieces.append(enumValues.joined(separator: " "))
            }
            if let valueSchema = parameter.valueSchema {
                pieces.append(schemaText(of: valueSchema))
            }
        }
        return pieces.joined(separator: " ")
    }

    private static func schemaText(of schema: ToolValueSchema) -> String {
        switch schema {
        case .scalar(let type, let enumValues):
            return ([type.rawValue] + (enumValues ?? [])).joined(separator: " ")
        case .object(let parameters):
            return schemaText(of: parameters)
        case .array(let element):
            return schemaText(of: element)
        }
    }
}

/// Characters divided by four is a heuristic, not an upper bound on provider token counts.
public struct HeuristicTokenEstimator: TokenEstimator {
    public init() {}

    public func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return (text.count + 3) / 4
    }
}

private enum JSONStringifier {
    static func string(for value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
