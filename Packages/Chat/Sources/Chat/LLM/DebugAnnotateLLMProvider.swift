#if DEBUG
import Core
import Foundation

/// Development-only `LLMProvider` that emits a canned `bible.annotate` tool
/// call instead of a chat reply, so the Bible annotation pipeline — tool
/// execution, repository write, reactive `@Query` render — is exercisable
/// end-to-end with no API key, network, or on-device model.
///
/// Works in *both* annotation entry points unchanged, because both funnel
/// through `ChatSession` → active `provider.stream(...)` → the tool loop:
/// in-chat ("annotate Romans 8:28-30") and the headless verse-tap "Add
/// annotation" flow (`BibleAnnotateDispatcher`, which sends a structured
/// `Reference id: …` prompt this provider parses). Selected via a seeded
/// `kind == .debug` row whose `modelId` is `Self.modelID`; the file is gated
/// on `#if DEBUG` and compiles out of Release entirely.
///
/// References the tool by its name string (no `Bible` import) — the same
/// approach `BibleAnnotateDispatcher` takes.
public struct DebugAnnotateLLMProvider: LLMProvider {
    public let id: String
    public let displayName: String = "Debug (annotate)"

    /// Stable model id used by the seeded `ModelConfigurationRecord`, and the
    /// discriminator `makeLLMProvider` switches on within the `.debug` arm.
    public static let modelID = "debug-annotate"
    public static let modelDisplayName = "Debug annotate"
    public static let maxContextTokens = 8_192

    /// Bible annotation tool id, held as a literal so Chat needn't import
    /// Bible — matches `BibleAnnotateDispatcher.bibleAnnotateToolID`.
    static let toolName = "bible.annotate"

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
                continuation.yield(.messageStart(id: "debug-annotate-\(UUID().uuidString)", model: model.id))

                // Loop termination: when *this* turn just ran the tool,
                // `ChatSession` re-invokes `stream()` with the tool result as
                // the trailing `.tool` turn (ContextAssembler maps it to
                // `.toolResult`). Emit a plain text turn with no tool call so
                // the loop ends — otherwise we'd annotate forever. Gate on the
                // *last* message, not "any `.tool` in history": a conversation
                // that earlier ran a different debug tool (e.g. the user sent a
                // note, then switched to this model) still ends in their fresh
                // user turn, and must trigger a new tool call.
                guard messages.last?.role != .tool else {
                    Self.emitDone(into: continuation)
                    continuation.finish()
                    return
                }

                do {
                    // Brief pre-stream pause so the "Waiting" spark is visible.
                    try await Task.sleep(nanoseconds: UInt64.random(in: 150...400) * 1_000_000)
                    let target = DebugBibleTarget.parse(from: messages)
                    continuation.yield(.contentBlockStart(index: 0, type: .toolUse))
                    continuation.yield(.toolUse(
                        index: 0,
                        id: "debug-tool-\(UUID().uuidString)",
                        name: Self.toolName,
                        input: Self.annotateInput(for: target),
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
        continuation.yield(.textDelta(index: 0, text: "Created a debug annotation."))
        continuation.yield(.contentBlockStop(index: 0))
        continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    // MARK: - Canned payload

    /// Build the `bible.annotate` `JSONValue` input for `target`, matching
    /// `AnnotateBibleTool.descriptor`'s parameter schema. Position fields are
    /// included only when the target carries them.
    static func annotateInput(for target: DebugBibleTarget) -> JSONValue {
        var fields: [String: JSONValue] = [
            "target": .string(target.target),
            "bookId": .string(target.bookId),
        ]
        if let chapter = target.chapterNumber { fields["chapterNumber"] = .int(chapter) }
        if let verseStart = target.verseStart { fields["verseStart"] = .int(verseStart) }
        if let verseEnd = target.verseEnd { fields["verseEnd"] = .int(verseEnd) }
        fields["entries"] = .array(entries(for: target).map { entry in
            .object([
                "category": .string(entry.category),
                "title": .string(entry.title),
                "body": .string(entry.body),
            ])
        })
        return .object(fields)
    }

    /// Canned multi-category entries shaped by target kind, mirroring
    /// `BibleAnnotateDispatcher.sectionGuidance`. The `reference` body is a
    /// bare citation string (the tool renders it as a navigation link).
    private static func entries(
        for target: DebugBibleTarget
    ) -> [(category: String, title: String, body: String)] {
        switch target.target {
        case "book":
            return [
                ("author", "Author", "Debug annotation: traditionally attributed authorship and the audience it addressed."),
                ("summary", "Overview", "Debug annotation: a one-paragraph summary of the book's arc and themes."),
                ("historical", "Historical context", "Debug annotation: the historical setting in which this book was written."),
            ]
        case "chapter":
            return [
                ("summary", "Chapter summary", "Debug annotation: what this chapter covers at a glance."),
                ("clarification", "Movements", "Debug annotation: a short outline of the chapter's sections."),
            ]
        default: // "verse"
            return [
                ("historical", "Historical context", "Debug annotation: the situation behind this passage."),
                ("clarification", "Plain meaning", "Debug annotation: a plain-language paraphrase of these verses."),
                ("reference", "See also", "Hebrews 4:15"),
            ]
        }
    }
}
#endif
