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
