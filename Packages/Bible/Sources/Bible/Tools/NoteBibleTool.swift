import Core
import Foundation

/// `ToolExecutor` that creates, edits, and deletes notes in the `bibleNote`
/// table on the assistant's behalf.
///
/// One tool, three actions — `create`, `edit`, `delete` — discriminated by an
/// `action` parameter so the LLM (Large Language Model) has a single note
/// capability rather than three. Notes are true per-row CRUD, so unlike
/// `bible.annotate` there is no whole-group replace: `create` inserts one
/// note, `edit` rewrites one note's body, `delete` removes one note by id.
///
/// Validation rejects inputs softly: a missing or malformed field returns a
/// `ToolResult` with `isError: true` and a remediation message instead of
/// throwing, so the model sees the failure and can retry with a correct
/// payload rather than tearing down the whole turn.
public struct NoteBibleTool: ToolExecutor {
    /// Dotted form namespaces the tool under its applet, matching
    /// `bible.annotate`, `time.now`, etc.
    public static let toolID = "bible.note"

    public static let appletID = "bible"

    public let toolID: String = NoteBibleTool.toolID

    private let repository: any BibleNoteRepository
    private let clock: any Clock
    private let ids: any IDGenerator
    private let stampProvider: any BibleNoteStampProvider

    public init(
        repository: any BibleNoteRepository,
        clock: any Clock = SystemClock(),
        ids: any IDGenerator = UUIDGenerator(),
        stampProvider: any BibleNoteStampProvider = DefaultBibleNoteStampProvider()
    ) {
        self.repository = repository
        self.clock = clock
        self.ids = ids
        self.stampProvider = stampProvider
    }

    public static let descriptor: LLMTool = LLMTool(
        id: NoteBibleTool.toolID,
        name: "bible.note",
        description: """
        Create, edit, or delete a free-text note on a book, chapter, or \
        verse range. A note is the reader's (or your) own prose — \
        reflections, cross-references, questions — not a formatted study \
        card. Keep notes concise unless the user asks for length.

        The `action` decides which other fields are required:
        - `"create"`: `target` plus its position fields, and `body`. \
        Inserts a new note; multiple notes can coexist on the same range.
        - `"edit"`: `id` and `body`. Rewrites that note's text.
        - `"delete"`: `id`. Removes that note.

        For `create`, `target` selects the scripture unit and decides the \
        position fields:
        - `"book"`: `bookId` (e.g. `"JHN"`); chapter/verse fields ignored.
        - `"chapter"`: `bookId` and `chapterNumber`; verse fields ignored.
        - `"verse"`: `bookId`, `chapterNumber`, `verseStart`, `verseEnd` \
        (set `verseEnd` equal to `verseStart` for a single verse).

        The `id` for `edit`/`delete` is the note id returned when it was \
        created or listed; don't invent one.
        """,
        category: .mutation,
        parameters: [
            LLMToolParameter(
                name: "action",
                type: .string,
                description: "What to do: 'create' a note, 'edit' an existing note's body, or 'delete' a note.",
                isRequired: true,
                enumValues: ["create", "edit", "delete"]
            ),
            LLMToolParameter(
                name: "id",
                type: .string,
                description: "Note id to edit or delete. Required for 'edit' and 'delete'; omit for 'create'.",
                isRequired: false
            ),
            LLMToolParameter(
                name: "target",
                type: .string,
                description: "For 'create': what the note attaches to — 'book', 'chapter', or 'verse'.",
                isRequired: false,
                enumValues: ["book", "chapter", "verse"]
            ),
            LLMToolParameter(
                name: "bookId",
                type: .string,
                description: "Three-letter UPPERCASE book code, e.g. 'GEN', 'ROM', 'JHN', '1PE'. Required for 'create'.",
                isRequired: false
            ),
            LLMToolParameter(
                name: "chapterNumber",
                type: .integer,
                description: "1-based chapter number. Required when creating with target 'chapter' or 'verse'.",
                isRequired: false
            ),
            LLMToolParameter(
                name: "verseStart",
                type: .integer,
                description: "1-based first verse in the range. Required when creating with target 'verse'.",
                isRequired: false
            ),
            LLMToolParameter(
                name: "verseEnd",
                type: .integer,
                description: "1-based last verse in the range, ≥ verseStart. Required when creating with target 'verse'; set equal to verseStart for a single verse.",
                isRequired: false
            ),
            LLMToolParameter(
                name: "body",
                type: .string,
                description: "The note text. Required for 'create' and 'edit'; must be non-empty.",
                isRequired: false
            ),
        ],
        appletId: NoteBibleTool.appletID,
        displayName: "Bible notes",
        summary: "Saves free-text notes on a passage."
    )

    /// Build a `ToolRegistration` ready to hand to `ToolRegistry.register(_:)`.
    /// The composition root calls this in each app's bootstrap.
    public static func registration(
        repository: any BibleNoteRepository,
        clock: any Clock = SystemClock(),
        ids: any IDGenerator = UUIDGenerator(),
        stampProvider: any BibleNoteStampProvider = DefaultBibleNoteStampProvider()
    ) -> ToolRegistration {
        ToolRegistration(
            tool: descriptor,
            execution: .local(NoteBibleTool(
                repository: repository,
                clock: clock,
                ids: ids,
                stampProvider: stampProvider
            )),
            isEnabled: true
        )
    }

    public func execute(input: [String: JSONValue]) async throws -> ToolResult {
        let action: Action
        do {
            action = try Self.validate(input: input)
        } catch let validation as ValidationError {
            return Self.errorResult(validation.message)
        }

        do {
            switch action {
            case .create(let create):
                return try await performCreate(create)
            case .edit(let id, let body):
                try await repository.update(id: id, body: body, updatedAt: clock.now())
                return Self.successResult("Updated the note.", id: id)
            case .delete(let id):
                try await repository.deleteOne(id: id)
                return Self.successResult("Deleted the note.", id: id)
            }
        } catch {
            return Self.errorResult("Failed to \(action.verb) the note: \(error.localizedDescription)")
        }
    }

    private func performCreate(_ create: ValidatedCreate) async throws -> ToolResult {
        let stamp = stampProvider.stamp()
        let now = clock.now()
        let note = BibleNoteRecord(
            id: ids.nextID(),
            target: create.target,
            bookId: create.bookId,
            chapterNumber: create.chapterNumber,
            verseStart: create.verseStart,
            verseEnd: create.verseEnd,
            body: create.body,
            source: stamp.source,
            modelId: stamp.modelId,
            createdAt: now,
            updatedAt: now
        )
        try await repository.insert(note)
        return Self.successResult("Wrote a note for the target.", id: note.id)
    }

    // MARK: - Validation

    private enum Action {
        case create(ValidatedCreate)
        case edit(id: String, body: String)
        case delete(id: String)

        var verb: String {
            switch self {
            case .create: "create"
            case .edit: "edit"
            case .delete: "delete"
            }
        }
    }

    private struct ValidatedCreate {
        let target: BibleNoteTarget
        let bookId: String
        let chapterNumber: Int?
        let verseStart: Int?
        let verseEnd: Int?
        let body: String
    }

    private struct ValidationError: Error {
        let message: String
    }

    private static func validate(input: [String: JSONValue]) throws -> Action {
        let actionRaw = try requireString(input, key: "action")
        switch actionRaw {
        case "create":
            return .create(try validateCreate(input))
        case "edit":
            let id = try requireNonEmptyString(input, key: "id")
            let body = try requireNonEmptyString(input, key: "body")
            return .edit(id: id, body: body)
        case "delete":
            let id = try requireNonEmptyString(input, key: "id")
            return .delete(id: id)
        default:
            throw ValidationError(message: "Unknown action '\(actionRaw)'. Use 'create', 'edit', or 'delete'.")
        }
    }

    private static func validateCreate(_ input: [String: JSONValue]) throws -> ValidatedCreate {
        let targetRaw = try requireString(input, key: "target")
        guard let target = BibleNoteTarget(rawValue: targetRaw) else {
            throw ValidationError(message: "Unknown target '\(targetRaw)'. Use 'book', 'chapter', or 'verse'.")
        }

        let bookId = try requireNonEmptyString(input, key: "bookId")
        let rawChapterNumber = optionalInt(input, key: "chapterNumber")
        let rawVerseStart = optionalInt(input, key: "verseStart")
        let rawVerseEnd = optionalInt(input, key: "verseEnd")

        // `target` is the authoritative discriminator. We enforce the fields
        // the unit *requires*, then coerce away any position fields it doesn't
        // use rather than rejecting the call (matches `bible.annotate`). The
        // coerced (nilled) fields are what get stored and queried back.
        let chapterNumber: Int?
        let verseStart: Int?
        let verseEnd: Int?
        switch target {
        case .book:
            chapterNumber = nil
            verseStart = nil
            verseEnd = nil
        case .chapter:
            guard let n = rawChapterNumber, n >= 1 else {
                throw ValidationError(message: "target 'chapter' requires chapterNumber ≥ 1.")
            }
            chapterNumber = n
            verseStart = nil
            verseEnd = nil
        case .verse:
            guard let n = rawChapterNumber, n >= 1 else {
                throw ValidationError(message: "target 'verse' requires chapterNumber ≥ 1.")
            }
            guard let start = rawVerseStart, start >= 1 else {
                throw ValidationError(message: "target 'verse' requires verseStart ≥ 1.")
            }
            guard let end = rawVerseEnd, end >= start else {
                throw ValidationError(message: "target 'verse' requires verseEnd ≥ verseStart.")
            }
            chapterNumber = n
            verseStart = start
            verseEnd = end
        }

        let body = try requireNonEmptyString(input, key: "body")
        return ValidatedCreate(
            target: target,
            bookId: bookId,
            chapterNumber: chapterNumber,
            verseStart: verseStart,
            verseEnd: verseEnd,
            body: body
        )
    }

    private static func requireString(_ input: [String: JSONValue], key: String) throws -> String {
        guard case .string(let value) = input[key] else {
            throw ValidationError(message: "\(key) is required and must be a string.")
        }
        return value
    }

    private static func requireNonEmptyString(_ input: [String: JSONValue], key: String) throws -> String {
        let value = try requireString(input, key: key)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError(message: "\(key) must not be empty.")
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

    private static func successResult(_ content: String, id: String) -> ToolResult {
        ToolResult(
            toolID: NoteBibleTool.toolID,
            content: content,
            isError: false,
            artifacts: [ToolResult.Artifact(type: "note", id: id)]
        )
    }

    private static func errorResult(_ message: String) -> ToolResult {
        ToolResult(
            toolID: NoteBibleTool.toolID,
            content: message,
            isError: true
        )
    }
}
