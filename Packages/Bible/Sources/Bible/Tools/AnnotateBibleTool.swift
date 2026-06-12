import Core
import Foundation

/// `ToolExecutor` that writes one markdown study summary per target into
/// the `bibleAnnotation` table.
///
/// One tool, three callers — single-target taps in the UI, in-chat tool
/// calls, and the bulk runner — all dispatch through this same
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
        Call this ONLY when the user explicitly asks to annotate a \
        passage — to "annotate" or "add study annotations to" a book, \
        chapter, or verse range. It writes one persistent markdown study \
        summary into the Bible reader. When the user just asks you to \
        explain, give context on, or summarize a passage, answer in the \
        conversation instead — do not call this tool (you may offer \
        annotating as a next step). For a free-text personal note or \
        reflection ("save a note", "note that…"), use the `bible.note` \
        tool instead, NOT this one.

        Produce ONE markdown study summary of the target passage in \
        `summary`. Long-form: roughly 150–400 words scaled to scope (a \
        verse range shorter, a whole book longer). Structure it with \
        short `###` headings, bold key terms, and bullet lists or \
        blockquotes where they genuinely help. Cover what the passage \
        says in plain language, authorship and historical context, and \
        notable cross-references — but cite a cross-reference ONLY when \
        the target text genuinely quotes, alludes to, or is quoted by \
        that passage; skip merely thematically similar verses. Cite \
        scripture with the full book name in `Book Chapter:Verse` form \
        (e.g. `Romans 8:28-30`, `Psalm 23`) — the reader auto-links \
        exactly that format into tappable references. Do NOT repeat the \
        target's own verse text verbatim; the reader displays it above \
        the summary.

        The `target` discriminates which scripture unit the annotation \
        attaches to and decides which position fields are required:
        - `"book"`: only `bookId` (e.g. `"ROM"`) — book overview.
        - `"chapter"`: `bookId` and `chapterNumber` — chapter summary.
        - `"verse"`: `bookId`, `chapterNumber`, `verseStart`, `verseEnd` \
        — verse-range summary. For a single verse, set `verseEnd` equal \
        to `verseStart`.

        Calling this tool replaces any existing annotation for the same \
        target. Call it at most once per target. There is no tool for \
        REMOVING an annotation — if the user asks you to delete one, \
        don't call this tool; tell them to open the annotation in the \
        reader and use its Delete action.
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
                name: "summary",
                type: .string,
                description: """
                Markdown study summary of the target passage, ~150–400 \
                words scaled to scope. Use short `###` headings, bold key \
                terms, and lists/blockquotes where helpful. Cite scripture \
                as full-book-name `Book Chapter:Verse` (e.g. 'Romans \
                8:28-30') so the reader auto-links it. Do not repeat the \
                target's own verse text verbatim.
                """,
                isRequired: true
            ),
        ],
        appletId: AnnotateBibleTool.appletID,
        displayName: "Bible annotations",
        summary: "Writes a markdown study summary for a passage."
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
        let record = BibleAnnotationRecord(
            id: ids.nextID(),
            target: parsed.target,
            bookId: parsed.bookId,
            chapterNumber: parsed.chapterNumber,
            verseStart: parsed.verseStart,
            verseEnd: parsed.verseEnd,
            summary: parsed.summary,
            source: stamp.source,
            modelId: stamp.modelId,
            createdAt: clock.now()
        )

        do {
            // `replace` clears the target's prior rows first, so re-annotating
            // converges on the intended one-row-per-target steady state.
            try await repository.replace(
                target: parsed.target,
                bookId: parsed.bookId,
                chapterNumber: parsed.chapterNumber,
                verseStart: parsed.verseStart,
                verseEnd: parsed.verseEnd,
                inserting: [record]
            )
        } catch {
            return Self.errorResult("Failed to write the annotation: \(error.localizedDescription)")
        }

        return ToolResult(
            toolID: AnnotateBibleTool.toolID,
            content: "Wrote an annotation for the target.",
            isError: false,
            artifacts: [ToolResult.Artifact(type: "annotation", id: record.id)]
        )
    }

    // MARK: - Validation

    private struct ValidatedInput {
        let target: BibleAnnotationTarget
        let bookId: String
        let chapterNumber: Int?
        let verseStart: Int?
        let verseEnd: Int?
        let summary: String
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

        let summary = try requireString(input, key: "summary")
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError(message: "summary is empty. Pass the markdown study summary text.")
        }

        return ValidatedInput(
            target: target,
            bookId: bookId,
            chapterNumber: chapterNumber,
            verseStart: verseStart,
            verseEnd: verseEnd,
            summary: summary
        )
    }

    private static func requireString(
        _ input: [String: JSONValue],
        key: String
    ) throws -> String {
        guard case .string(let value) = input[key] else {
            throw ValidationError(message: "\(key) is required and must be a string.")
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
