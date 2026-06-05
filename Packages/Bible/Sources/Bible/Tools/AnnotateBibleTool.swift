import Core
import Foundation

/// `ToolExecutor` that writes annotation cards into the `bibleAnnotation`
/// table.
///
/// One tool, three callers — single-target taps in the UI, in-chat tool
/// calls, and (future) the bulk runner — all dispatch through this same
/// executor. The provenance fields (`source`, `modelId`) come from an
/// injected `BibleAnnotationStampProvider` so the bulk path can stamp
/// `.userBulk` without a separate tool, and tests substitute fakes.
///
/// Validation rejects inputs softly: a missing required field returns a
/// `ToolResult` with `isError: true` and a remediation message instead of
/// throwing, so the LLM (Large Language Model) sees the failure and can
/// retry with a correct payload rather than tearing down the whole turn.
public struct AnnotateBibleTool: ToolExecutor {
    /// Dotted form namespaces the tool under its applet, matching the
    /// convention started by `time.now` (Chat) and inherited by future
    /// applets (`todo.create`, `recipe.find`, …).
    public static let toolID = "bible.annotate"

    public static let appletID = "bible"

    public let toolID: String = AnnotateBibleTool.toolID

    private let repository: any BibleAnnotationRepository
    private let clock: any Clock
    private let ids: any IDGenerator
    private let stampProvider: any BibleAnnotationStampProvider

    public init(
        repository: any BibleAnnotationRepository,
        stampProvider: any BibleAnnotationStampProvider,
        clock: any Clock = SystemClock(),
        ids: any IDGenerator = UUIDGenerator()
    ) {
        self.repository = repository
        self.clock = clock
        self.ids = ids
        self.stampProvider = stampProvider
    }

    public static let descriptor: LLMTool = LLMTool(
        id: AnnotateBibleTool.toolID,
        name: "bible.annotate",
        description: """
        Produce one or more annotation cards for a book, chapter, or \
        verse range. Each card is a short, focused note classified by \
        `category`. Keep each body to ~240 characters / ≤2 sentences \
        unless the user explicitly asks for more depth — readers see \
        these in a tight popover.

        Each entry's `category` is one of: `author`, `summary`, \
        `historical`, `clarification`, `reference`. The category sets \
        both the card's display order (author → summary → historical → \
        clarification → reference) and its rendering:
        - `reference`: the body MUST be a single bare scripture citation \
        like `"Heb 4:15"` or `"Romans 8:28-30"` — nothing else — so it \
        renders as a tappable navigation link. If what you want to say is \
        prose *about* a passage, use `clarification` and cite the passage \
        inside the sentence instead.
        - every other category: the body is markdown prose.
        Use clear, plain-language titles (e.g. `"Author"`, \
        `"Historical context"`, `"See also"`).

        The `target` discriminates which scripture unit the annotation \
        attaches to and decides which position fields are required:
        - `"book"`: only `bookId` (e.g. `"ROM"`) — book prologue.
        - `"chapter"`: `bookId` and `chapterNumber` — chapter summary.
        - `"verse"`: `bookId`, `chapterNumber`, `verseStart`, `verseEnd` \
        — verse-range note. For a single verse, set `verseEnd` equal \
        to `verseStart`.

        Calling this tool replaces any existing annotation cards for \
        the same target. Pass an empty `entries` array to clear them.
        """,
        category: .mutation,
        parameters: [
            LLMToolParameter(
                name: "target",
                type: .string,
                description: "What scripture unit the annotation attaches to: 'book', 'chapter', or 'verse'.",
                isRequired: true,
                enumValues: ["book", "chapter", "verse"]
            ),
            LLMToolParameter(
                name: "bookId",
                type: .string,
                description: "Three-letter UPPERCASE book code, e.g. 'GEN', 'ROM', 'JHN', '1PE'.",
                isRequired: true
            ),
            LLMToolParameter(
                name: "chapterNumber",
                type: .integer,
                description: "1-based chapter number. Required when target is 'chapter' or 'verse'; omit for 'book'.",
                isRequired: false
            ),
            LLMToolParameter(
                name: "verseStart",
                type: .integer,
                description: "1-based first verse in the range. Required when target is 'verse'; omit otherwise.",
                isRequired: false
            ),
            LLMToolParameter(
                name: "verseEnd",
                type: .integer,
                description: "1-based last verse in the range, ≥ verseStart. Required when target is 'verse'; set equal to verseStart for a single verse.",
                isRequired: false
            ),
            LLMToolParameter(
                name: "entries",
                type: .array,
                description: """
                Array of annotation card objects. Each object has: \
                `category` ('author', 'summary', 'historical', \
                'clarification', or 'reference'), `title` (short \
                heading), `body` (for 'reference': a citation string like \
                'John 1:14' or 'Romans 8:28-30'; for every other \
                category: markdown content). An empty array clears \
                existing annotations for the target without inserting new \
                ones.
                """,
                isRequired: true,
                // The array's element schema (JSON-Schema `items`). The native
                // Gemini adapter rejects an array parameter declared without it
                // (HTTP 400) — see `JSONToolSchema`. For an `.array` parameter
                // the `valueSchema` describes each item directly.
                valueSchema: .object([
                    LLMToolParameter(
                        name: "category",
                        type: .string,
                        description: "One of: 'author', 'summary', 'historical', 'clarification', 'reference'.",
                        isRequired: true,
                        enumValues: ["author", "summary", "historical", "clarification", "reference"]
                    ),
                    LLMToolParameter(
                        name: "title",
                        type: .string,
                        description: "Short, plain-language card heading (e.g. 'Author', 'Historical context').",
                        isRequired: true
                    ),
                    LLMToolParameter(
                        name: "body",
                        type: .string,
                        description: "For 'reference': a bare scripture citation like 'Heb 4:15'. For every other category: markdown prose, ~240 chars / ≤2 sentences.",
                        isRequired: true
                    ),
                ])
            ),
        ],
        appletId: AnnotateBibleTool.appletID,
        displayName: "Bible annotations",
        summary: "Adds study annotation cards to a passage."
    )

    /// Build a `ToolRegistration` ready to hand to `ToolRegistry.register(_:)`.
    /// The composition root calls this in each app's bootstrap.
    public static func registration(
        repository: any BibleAnnotationRepository,
        stampProvider: any BibleAnnotationStampProvider,
        clock: any Clock = SystemClock(),
        ids: any IDGenerator = UUIDGenerator()
    ) -> ToolRegistration {
        ToolRegistration(
            tool: descriptor,
            execution: .local(AnnotateBibleTool(
                repository: repository,
                stampProvider: stampProvider,
                clock: clock,
                ids: ids
            )),
            isEnabled: true
        )
    }

    public func execute(input: [String: JSONValue]) async throws -> ToolResult {
        let parsed: ValidatedInput
        do {
            parsed = try Self.validate(input: input)
        } catch let validation as ValidationError {
            return Self.errorResult(validation.message)
        }

        let stamp = await stampProvider.stamp()
        let now = clock.now()
        // Stamp each entry 1 ms apart in emission order. `createdAt` is the
        // secondary sort key after `category`, so same-category siblings
        // (e.g. several `reference` cards) keep the order the LLM produced
        // them in rather than tie-breaking on their random UUID `id` — which
        // would re-shuffle on every regeneration.
        let records = parsed.entries.enumerated().map { index, entry in
            BibleAnnotationRecord(
                id: ids.nextID(),
                target: parsed.target,
                bookId: parsed.bookId,
                chapterNumber: parsed.chapterNumber,
                verseStart: parsed.verseStart,
                verseEnd: parsed.verseEnd,
                category: entry.category,
                title: entry.title,
                body: entry.body,
                source: stamp.source,
                modelId: stamp.modelId,
                createdAt: now.addingTimeInterval(Double(index) * 0.001)
            )
        }

        do {
            try await repository.replace(
                target: parsed.target,
                bookId: parsed.bookId,
                chapterNumber: parsed.chapterNumber,
                verseStart: parsed.verseStart,
                verseEnd: parsed.verseEnd,
                inserting: records
            )
        } catch {
            return Self.errorResult("Failed to write annotations: \(error.localizedDescription)")
        }

        let artifacts = records.map {
            ToolResult.Artifact(type: "annotation", id: $0.id)
        }
        let content = records.isEmpty
            ? "Cleared annotations for the target."
            : "Wrote \(records.count) annotation\(records.count == 1 ? "" : "s") for the target."
        return ToolResult(
            toolID: AnnotateBibleTool.toolID,
            content: content,
            isError: false,
            artifacts: artifacts
        )
    }

    // MARK: - Validation

    private struct ValidatedInput {
        let target: BibleAnnotationTarget
        let bookId: String
        let chapterNumber: Int?
        let verseStart: Int?
        let verseEnd: Int?
        let entries: [ValidatedEntry]
    }

    private struct ValidatedEntry {
        let category: BibleAnnotationCategory
        let title: String
        let body: String
    }

    private struct ValidationError: Error {
        let message: String
    }

    private static func validate(input: [String: JSONValue]) throws -> ValidatedInput {
        let targetRaw = try requireString(input, key: "target")
        guard let target = BibleAnnotationTarget(rawValue: targetRaw) else {
            throw ValidationError(message: "Unknown target '\(targetRaw)'. Use 'book', 'chapter', or 'verse'.")
        }

        let bookId = try requireString(input, key: "bookId")
        guard !bookId.isEmpty else {
            throw ValidationError(message: "bookId is empty. Pass a 3-letter UPPERCASE book code like 'ROM' or '1PE'.")
        }

        let chapterNumber = optionalInt(input, key: "chapterNumber")
        let verseStart = optionalInt(input, key: "verseStart")
        let verseEnd = optionalInt(input, key: "verseEnd")

        // Required-by-target validation. The `guard let X, X >= 1`
        // shorthand shadows the outer optional with its unwrapped value
        // so the comparison reads naturally; the shadowed binding is
        // intentionally not used past the guard.
        switch target {
        case .book:
            if chapterNumber != nil || verseStart != nil || verseEnd != nil {
                throw ValidationError(message: "target 'book' must not include chapterNumber, verseStart, or verseEnd.")
            }
        case .chapter:
            guard let chapterNumber, chapterNumber >= 1 else {
                throw ValidationError(message: "target 'chapter' requires chapterNumber ≥ 1.")
            }
            if verseStart != nil || verseEnd != nil {
                throw ValidationError(message: "target 'chapter' must not include verseStart or verseEnd.")
            }
        case .verse:
            guard let chapterNumber, chapterNumber >= 1 else {
                throw ValidationError(message: "target 'verse' requires chapterNumber ≥ 1.")
            }
            guard let verseStart, verseStart >= 1 else {
                throw ValidationError(message: "target 'verse' requires verseStart ≥ 1.")
            }
            guard let verseEnd, verseEnd >= verseStart else {
                throw ValidationError(message: "target 'verse' requires verseEnd ≥ verseStart.")
            }
        }

        let entriesRaw = try requireArray(input, key: "entries")
        var entries: [ValidatedEntry] = []
        for (index, item) in entriesRaw.enumerated() {
            entries.append(try validateEntry(item, at: index))
        }

        return ValidatedInput(
            target: target,
            bookId: bookId,
            chapterNumber: chapterNumber,
            verseStart: verseStart,
            verseEnd: verseEnd,
            entries: entries
        )
    }

    private static func validateEntry(_ value: JSONValue, at index: Int) throws -> ValidatedEntry {
        guard case .object(let fields) = value else {
            throw ValidationError(message: "entries[\(index)] is not an object.")
        }
        let categoryRaw = try requireString(fields, key: "category", context: "entries[\(index)]")
        guard let category = BibleAnnotationCategory(toolToken: categoryRaw) else {
            let valid = BibleAnnotationCategory.allCases.map { "'\($0.toolToken)'" }.joined(separator: ", ")
            throw ValidationError(message: "entries[\(index)] has unknown category '\(categoryRaw)'. Use one of: \(valid).")
        }
        let title = try requireString(fields, key: "title", context: "entries[\(index)]")
        let body = try requireString(fields, key: "body", context: "entries[\(index)]")
        return ValidatedEntry(category: category, title: title, body: body)
    }

    private static func requireString(
        _ input: [String: JSONValue],
        key: String,
        context: String? = nil
    ) throws -> String {
        guard case .string(let value) = input[key] else {
            let prefix = context.map { "\($0)." } ?? ""
            throw ValidationError(message: "\(prefix)\(key) is required and must be a string.")
        }
        return value
    }

    private static func requireArray(
        _ input: [String: JSONValue],
        key: String
    ) throws -> [JSONValue] {
        guard case .array(let value) = input[key] else {
            throw ValidationError(message: "\(key) is required and must be an array.")
        }
        return value
    }

    private static func optionalInt(_ input: [String: JSONValue], key: String) -> Int? {
        guard let raw = input[key] else { return nil }
        if case .int(let value) = raw { return value }
        if case .double(let value) = raw {
            // Some providers serialize integers as doubles; round-trip safely.
            let rounded = Int(value)
            return Double(rounded) == value ? rounded : nil
        }
        return nil
    }

    private static func errorResult(_ message: String) -> ToolResult {
        ToolResult(
            toolID: AnnotateBibleTool.toolID,
            content: message,
            isError: true
        )
    }
}
