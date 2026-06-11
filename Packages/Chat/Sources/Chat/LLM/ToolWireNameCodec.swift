import Core
import Foundation

/// Sanitizer for providers whose APIs restrict function-tool names to
/// `[A-Za-z0-9_-]` — OpenAI (`Invalid 'tools[0].name': string does not match
/// pattern`) and Anthropic (`tools.0.custom.name: String should match
/// pattern`). Super's tool IDs are dot-namespaced (`time.now`, `bible.read`),
/// so the strict adapters put the sanitized *wire* name on requests and
/// restore the original registry name on decode via ``ToolWireNameMap``.
/// Gemini permits dots and bypasses this entirely.
enum ToolWireNameCodec {
    /// Replace every character outside `[A-Za-z0-9_-]` with `_`
    /// (`time.now` → `time_now`). Identity for already-legal names.
    static func sanitized(_ name: String) -> String {
        guard name.unicodeScalars.contains(where: { !isAllowed($0) }) else { return name }
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            scalars.append(isAllowed(scalar) ? scalar : "_")
        }
        return String(scalars)
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "a" && scalar <= "z")
            || (scalar >= "A" && scalar <= "Z")
            || (scalar >= "0" && scalar <= "9")
            || scalar == "_"
            || scalar == "-"
    }
}

/// Per-request bidirectional tool-name map, built once from the turn's
/// advertised tools. Encode goes through ``wireName(forOriginal:)``; streamed
/// tool calls come back through ``originalName(forWire:)`` so the
/// `ToolRegistry` exact-match lookup (`registrations[toolID]`) still receives
/// the dot-namespaced name it is keyed by.
struct ToolWireNameMap: Sendable {
    private let wireByOriginal: [String: String]
    private let originalByWire: [String: String]

    init(tools: [LLMTool]) {
        var wireByOriginal: [String: String] = [:]
        var originalByWire: [String: String] = [:]
        for tool in tools {
            let original = tool.name
            guard wireByOriginal[original] == nil else { continue }
            var wire = ToolWireNameCodec.sanitized(original)
            // Two distinct originals sanitizing identically (`a.b` vs `a_b`)
            // is a tool-naming bug, but keep the request valid rather than
            // silently dropping a tool: suffix deterministically.
            if originalByWire[wire] != nil {
                var ordinal = 2
                while originalByWire["\(wire)_\(ordinal)"] != nil { ordinal += 1 }
                wire = "\(wire)_\(ordinal)"
            }
            wireByOriginal[original] = wire
            originalByWire[wire] = original
        }
        self.wireByOriginal = wireByOriginal
        self.originalByWire = originalByWire
    }

    /// Wire name for an advertised tool. A name absent from the map (replayed
    /// history of a tool no longer advertised this turn) falls back to the
    /// pure sanitizer so encode stays consistent across turns.
    func wireName(forOriginal name: String) -> String {
        wireByOriginal[name] ?? ToolWireNameCodec.sanitized(name)
    }

    /// Original registry name for a streamed wire name. Unknown names (server
    /// tools, a model inventing a name) pass through unchanged.
    func originalName(forWire name: String) -> String {
        originalByWire[name] ?? name
    }

    /// Restore the original tool name on a streamed `.toolUse` event; every
    /// other event passes through unchanged. Adapters route all yielded
    /// reducer events through this so the mapping cannot miss an emission site.
    func restoringToolName(in event: LLMStreamEvent) -> LLMStreamEvent {
        guard case .toolUse(let index, let id, let name, let input, let signature) = event else {
            return event
        }
        return .toolUse(
            index: index,
            id: id,
            name: originalName(forWire: name),
            input: input,
            signature: signature
        )
    }
}
