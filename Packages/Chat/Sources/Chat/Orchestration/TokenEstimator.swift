import Core
import Foundation

/// Estimates the token cost of arbitrary text. The MVP ships a chars/4
/// heuristic; the protocol seam lets a real BPE (Byte-Pair Encoding)
/// tokenizer drop in later without touching `ContextAssembler` or
/// `Compactor` callers.
///
/// Implementations must be deterministic and side-effect free — the
/// orchestrator calls `estimate(...)` on the hot path before every turn.
public protocol TokenEstimator: Sendable {
    /// Approximate token count for a single string. Empty strings return 0.
    func estimate(_ text: String) -> Int
}

extension TokenEstimator {
    /// Sum the per-block text cost across a sequence of `LLMMessage`s.
    /// Tool-use payloads contribute their JSON (JavaScript Object Notation)
    /// serialization length so a verbose `input` argument shows up in the
    /// budget.
    public func estimate(messages: [LLMMessage]) -> Int {
        var total = 0
        for message in messages {
            for block in message.content {
                switch block {
                case .text(let text):
                    total += estimate(text)
                case .toolUse(_, let name, let input, _):
                    total += estimate(name)
                    total += estimate(JSONStringifier.string(for: input))
                case .toolResult(_, let content, _):
                    total += estimate(content)
                case .searchResult(let sources):
                    // Replayed search results are re-serialized into the
                    // provider request (Anthropic), so they consume budget:
                    // count each citation's title + snippet. The opaque
                    // encrypted echo is provider-side weight we can't size
                    // here, so this is a floor, not an exact count — safe for
                    // a budget meter that already overshoots.
                    for source in sources {
                        total += estimate(source.title)
                        if let snippet = source.snippet { total += estimate(snippet) }
                    }
                }
            }
        }
        return total
    }

    /// Sum the token cost of the tool *definitions* sent alongside the prompt.
    /// Tool schemas (name + LLM-facing description + the full parameter shape)
    /// are serialized into every provider request and counted against the
    /// model's context window, yet they live outside `[LLMMessage]` — so a
    /// context meter that only sums `messages` silently undercounts by the
    /// fixed tool overhead (≈1–1.5K tokens for an applet with several verbose
    /// tools), which on a small-window model like the Apple Foundation Model
    /// is the difference between "well under budget" and an overflow. Counting
    /// the descriptive text via the same `chars/4` heuristic gives a floor:
    /// it ignores per-provider JSON-Schema scaffolding (braces, keys), which
    /// only makes the estimate more conservative.
    public func estimate(tools: [LLMTool]) -> Int {
        var total = 0
        for tool in tools {
            total += estimate(tool.name)
            total += estimate(tool.description)
            total += estimate(Self.schemaText(of: tool.parameters))
        }
        return total
    }

    /// Flatten a tool's parameters (and any nested `.array` / `.object`
    /// `valueSchema`) into a single string whose length stands in for the
    /// serialized JSON-Schema weight. Captures every field the model actually
    /// reads — each parameter's name, type, description, and enum constraint —
    /// recursing into nested element schemas so a deeply-shaped parameter
    /// (e.g. `read`'s array-of-objects `passages`) isn't undercounted.
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

    /// Recurse a nested element schema into its flattened text.
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

/// chars/4 heuristic. This roughly matches `cl100k_base` for English prose
/// (which averages ~4 characters per token) and overshoots for dense code
/// — both safe directions for a budget meter.
public struct HeuristicTokenEstimator: TokenEstimator {
    public init() {}

    public func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        // Round up so a 1–3 character message still counts as 1 token.
        return (text.count + 3) / 4
    }
}

/// Stable JSON serialization used for token estimation only — keys sorted
/// so the same `JSONValue` always produces the same byte length.
private enum JSONStringifier {
    static func string(for value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
