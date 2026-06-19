#if DEBUG
import Core
import Foundation

/// Development-only `LLMProvider` that emits a canned `bible.highlight` tool
/// call from the user's turn, so the highlight pipeline — tool execution,
/// repository read/write, reactive `@Query` render — is exercisable end-to-end
/// with no API key, network, or on-device model.
///
/// The turn drives all three pieces of the call:
/// - **action**: an explicit `action:<read|search|set|clear>` directive wins;
///   otherwise it is inferred — "clear"/"unhighlight"/"remove" → `clear`; a
///   colour plus a "search"/"find"/"list"/"which" word → `search`; a bare
///   colour → `set`; nothing else → `read`.
/// - **reference**: parsed by `DebugBibleTarget` (the same notation parser the
///   read/annotate debug providers use), e.g. "John 3:16-17", "Psalm 23".
/// - **colour**: the first of yellow/green/blue/pink/lavender named in the turn
///   (defaulting to yellow for `set`/`search`, which require one).
///
/// Examples: "highlight John 3:16 green" → `set`; "what did I highlight in
/// John 3" → `read`; "find my yellow highlights" → `search`; "clear the
/// highlight on John 3:16" → `clear`.
///
/// Selected via a seeded `kind == .debug` row whose `modelId` is `Self.modelID`;
/// the file is gated on `#if DEBUG` and compiles out of Release entirely.
/// References the tool by its name string (no `Bible` import), matching the
/// other debug Bible providers.
public struct DebugHighlightLLMProvider: LLMProvider {
    public let id: String
    public let displayName: String = "Debug (highlight)"

    /// Stable model id used by the seeded `ModelConfigurationRecord`, and the
    /// discriminator `makeLLMProvider` switches on within the `.debug` arm.
    public static let modelID = "debug-highlight"
    public static let modelDisplayName = "Debug highlight"
    public static let maxContextTokens = 8_192

    /// Bible highlight tool id, held as a literal so Chat needn't import Bible.
    static let toolName = "bible.highlight"

    /// Colour used when `set`/`search` need one and the turn names none.
    static let fallbackColor = "yellow"

    /// The five highlight colours, mirroring `BibleHighlightColor` (Chat can't
    /// import Bible). A debug-only literal; the Bible tool is the source of truth.
    static let colors = ["yellow", "green", "blue", "pink", "lavender"]

    public var supportedModels: [LLMModel] {
        [LLMModel(
            id: Self.modelID,
            displayName: Self.modelDisplayName,
            supportsThinking: false,
            supportsTools: true,
            maxContextTokens: Self.maxContextTokens
        )]
    }

    public init(id: String) {
        self.id = id
    }

    public func stream(
        messages: [LLMMessage],
        model: LLMModel,
        tools: [LLMTool],
        temperature: Double
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.messageStart(id: "debug-highlight-\(UUID().uuidString)", model: model.id))

                // Loop termination: once this turn ran the tool, `ChatSession`
                // re-invokes `stream()` with the tool result as the trailing
                // `.tool` turn. Emit a plain text turn with no tool call so the
                // loop ends. Gate on the *last* message, not "any `.tool` in
                // history", so a fresh user turn still triggers a new call.
                guard messages.last?.role != .tool else {
                    Self.emitDone(into: continuation)
                    continuation.finish()
                    return
                }

                do {
                    // Brief pre-stream pause so the "Waiting" spark is visible.
                    try await Task.sleep(nanoseconds: UInt64.random(in: 150...400) * 1_000_000)
                    continuation.yield(.contentBlockStart(index: 0, type: .toolUse))
                    continuation.yield(.toolUse(
                        index: 0,
                        id: "debug-tool-\(UUID().uuidString)",
                        name: Self.toolName,
                        input: Self.highlightInput(from: messages),
                        signature: nil
                    ))
                    continuation.yield(.contentBlockStop(index: 0))
                    continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
                } catch is CancellationError {
                    continuation.yield(.error(.cancelled))
                    continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
                } catch {
                    continuation.yield(.error(.requestFailed(error.localizedDescription)))
                    continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func emitDone(
        into continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) {
        continuation.yield(.contentBlockStart(index: 0, type: .text))
        continuation.yield(.textDelta(index: 0, text: "Handled the highlight request."))
        continuation.yield(.contentBlockStop(index: 0))
        continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    // MARK: - Canned payload

    /// Build the `bible.highlight` `JSONValue` input from the turn, matching
    /// `HighlightBibleTool.descriptor`'s parameter schema. `set`/`clear` always
    /// carry a verse range (defaulting to verse 1 when the reference names only
    /// a book or chapter); `read` omits the range for a whole-chapter reference;
    /// `search` carries the colour and, when the turn names a book, that scope.
    static func highlightInput(from messages: [LLMMessage]) -> JSONValue {
        let action = self.action(from: messages)
        switch action {
        case "search":
            var fields: [String: JSONValue] = [
                "action": .string("search"),
                "color": .string(color(from: messages) ?? fallbackColor),
            ]
            // Scope to a book only when the turn explicitly names one.
            if let book = DebugBibleTarget.parseFreeText(lastUserText(from: messages))?.bookId {
                fields["book"] = .string(book)
            }
            return .object(fields)
        case "read":
            let target = DebugBibleTarget.parse(from: messages)
            var fields: [String: JSONValue] = [
                "action": .string("read"),
                "book": .string(target.bookId),
                "chapter": .int(target.chapterNumber ?? 1),
            ]
            applyRange(target, into: &fields, requireRange: false)
            return .object(fields)
        case "clear":
            let target = DebugBibleTarget.parse(from: messages)
            var fields: [String: JSONValue] = [
                "action": .string("clear"),
                "book": .string(target.bookId),
                "chapter": .int(target.chapterNumber ?? 1),
            ]
            applyRange(target, into: &fields, requireRange: true)
            return .object(fields)
        default: // "set"
            let target = DebugBibleTarget.parse(from: messages)
            var fields: [String: JSONValue] = [
                "action": .string("set"),
                "book": .string(target.bookId),
                "chapter": .int(target.chapterNumber ?? 1),
                "color": .string(color(from: messages) ?? fallbackColor),
            ]
            applyRange(target, into: &fields, requireRange: true)
            return .object(fields)
        }
    }

    /// Copy the target's verse range into `fields`. `set`/`clear` need a range,
    /// so a reference without one defaults to verse 1; `read` leaves the range
    /// off for a whole-chapter reference.
    private static func applyRange(
        _ target: DebugBibleTarget, into fields: inout [String: JSONValue], requireRange: Bool
    ) {
        if let verseStart = target.verseStart {
            fields["verseStart"] = .int(verseStart)
            if let verseEnd = target.verseEnd, verseEnd != verseStart {
                fields["verseEnd"] = .int(verseEnd)
            }
        } else if requireRange {
            fields["verseStart"] = .int(1)
        }
    }

    // MARK: - Parsing

    /// Regex for the optional `action:<mode>` directive — case-insensitive, on a
    /// word boundary so it isn't matched inside a longer token.
    private static let actionDirective = #"(?i)\baction:(read|search|set|clear)\b"#

    /// The action for this turn: an explicit `action:<mode>` directive wins;
    /// otherwise inferred from the phrasing and whether a colour is named.
    static func action(from messages: [LLMMessage]) -> String {
        let text = lastUserText(from: messages)
        if let range = text.range(of: actionDirective, options: .regularExpression),
           let mode = text[range].split(separator: ":").last {
            return mode.lowercased()
        }
        let lower = text.lowercased()
        if lower.contains("unhighlight") || lower.contains("clear") || lower.contains("remove") {
            return "clear"
        }
        let hasColor = color(from: messages) != nil
        let searchy = ["search", "find", "list", "which", "what verses"].contains { lower.contains($0) }
        if hasColor && searchy { return "search" }
        if hasColor { return "set" }
        return "read"
    }

    /// The first highlight colour named in the turn (word-bounded,
    /// case-insensitive), or `nil` when none is present.
    static func color(from messages: [LLMMessage]) -> String? {
        let lower = lastUserText(from: messages).lowercased()
        return colors.first { color in
            lower.range(of: #"\b\#(color)\b"#, options: .regularExpression) != nil
        }
    }

    /// The trimmed text of the most recent user turn, or `""` when there is none.
    static func lastUserText(from messages: [LLMMessage]) -> String {
        guard let lastUser = messages.last(where: { $0.role == .user }) else { return "" }
        return lastUser.content
            .compactMap { block -> String? in
                if case .text(let value) = block { return value }
                return nil
            }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
