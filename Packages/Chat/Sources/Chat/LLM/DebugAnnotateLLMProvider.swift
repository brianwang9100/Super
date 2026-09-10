#if DEBUG
import Core
import Foundation

/// Foreground requests without tools stream canned Markdown; chat and bulk requests exercise the annotation tool loop.
public struct DebugAnnotateLLMProvider: LLMProvider {
    public let id: String
    public let displayName: String = "Debug (annotate)"

    public static let modelID = "debug-annotate"
    public static let modelDisplayName = "Debug annotate"
    // Keep annotation tools available in the in-chat preview; compact models
    // intentionally omit mutation tools through CompactToolPolicy.
    public static let maxContextTokens = 32_768

    /// Kept as a literal so Chat does not import Bible.
    static let toolName = "bible.annotate"

    public var supportedModels: [LLMModel] {
        [LLMModel(
            id: Self.modelID,
            displayName: Self.modelDisplayName,
            supportsThinking: false,
            supportsTools: true,
            maxContextTokens: Self.maxContextTokens
        ),]
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

                // Stop after this turn's tool result, not any historical result, or later user requests would be ignored.
                guard messages.last?.role != .tool else {
                    Self.emitDone(into: continuation)
                    continuation.finish()
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: UInt64.random(in: 150...400) * 1_000_000)
                    let target = DebugBibleTarget.parse(from: messages)
                    if tools.isEmpty {
                        continuation.yield(.contentBlockStart(index: 0, type: .text))
                        let text = Self.summary(for: target)
                        var start = text.startIndex
                        while start < text.endIndex {
                            try Task.checkCancellation()
                            let end = text.index(start, offsetBy: 12, limitedBy: text.endIndex) ?? text.endIndex
                            continuation.yield(.textDelta(index: 0, text: String(text[start..<end])))
                            start = end
                            try await Task.sleep(for: .milliseconds(65))
                        }
                        continuation.yield(.contentBlockStop(index: 0))
                        continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
                        continuation.finish()
                        return
                    }
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

    static func annotateInput(for target: DebugBibleTarget) -> JSONValue {
        var fields: [String: JSONValue] = [
            "target": .string(target.target),
            "bookId": .string(target.bookId),
        ]
        if let chapter = target.chapterNumber { fields["chapterNumber"] = .int(chapter) }
        if let verseStart = target.verseStart { fields["verseStart"] = .int(verseStart) }
        if let verseEnd = target.verseEnd { fields["verseEnd"] = .int(verseEnd) }
        fields["summary"] = .string(summary(for: target))
        return .object(fields)
    }

    /// Exercises headings, emphasis, lists, blockquotes, and Bible reference links.
    private static func summary(for target: DebugBibleTarget) -> String {
        switch target.target {
        case "book":
            return """
            ### Authorship & date
            Debug annotation: **traditionally attributed** authorship, the \
            audience addressed, and the approximate date of composition.

            ### Overview
            Debug annotation: a short summary of the book's arc and major \
            themes.

            - First movement of the book
            - Second movement of the book

            ### Historical setting
            Debug annotation: the situation in which this book was written. \
            Compare Psalm 23 for a related image.
            """
        case "chapter":
            return """
            ### Summary
            Debug annotation: what this chapter covers at a glance, with a \
            **key term** marked for emphasis.

            ### Movements
            - Opening section
            - Central argument
            - Closing exhortation

            > Debug blockquote: a short editorial aside about the chapter.
            """
        default: // "verse"
            return """
            ### Plain meaning
            Debug annotation: a plain-language paraphrase of these verses, \
            with the **pivotal phrase** in bold.

            ### Context
            Debug annotation: the situation behind this passage.

            ### Cross-references
            This passage echoes Hebrews 4:15 — tap the citation to jump \
            there.
            """
        }
    }
}
#endif
