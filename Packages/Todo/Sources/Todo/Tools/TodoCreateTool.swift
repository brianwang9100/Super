import Core
import Foundation

/// `ToolExecutor` that creates one or more tasks in the `task` table on the
/// assistant's behalf.
///
/// The LLM (Large Language Model) passes a single `tasks` parameter holding a
/// JSON array of task objects, which the tool parses itself — the flat
/// tool-parameter model has no native array-of-objects schema, so a JSON
/// string is the way to carry per-item fields (`title`, `priority`, `dueAt`,
/// `notes`) in one call. Validation is all-or-nothing: the whole batch is
/// validated before any row is written, so a malformed item fails the call
/// up front rather than leaving the valid items half-created. (The writes
/// themselves are one transaction per row, so a — near-impossible — mid-batch
/// SQLite failure is reported but not rolled back.)
///
/// Validation rejects inputs softly: a missing or malformed payload returns a
/// `ToolResult` with `isError: true` and a remediation message instead of
/// throwing, so the model sees the failure and can retry with a corrected
/// payload rather than tearing down the whole turn. Mirrors `NoteBibleTool`.
public struct TodoCreateTool: ToolExecutor {
    /// Dotted form namespaces the tool under its applet, matching
    /// `bible.note`, `time.now`, etc. The DEBUG-only
    /// `DebugTodoLLMProvider.toolName` (Chat package) hard-codes this same
    /// string by literal so Chat needn't import Todo — keep the two in sync
    /// if this is ever renamed.
    public static let toolID = "todo.create"

    public static let appletID = "todo"

    public let toolID: String = TodoCreateTool.toolID

    private let repository: any TaskRepository
    private let clock: any Clock
    private let ids: any IDGenerator

    public init(
        repository: any TaskRepository,
        clock: any Clock = SystemClock(),
        ids: any IDGenerator = UUIDGenerator()
    ) {
        self.repository = repository
        self.clock = clock
        self.ids = ids
    }

    public static let descriptor: LLMTool = LLMTool(
        id: TodoCreateTool.toolID,
        name: "todo.create",
        description: """
        Create one or more tasks in the user's Todo list. Only call this when \
        the user explicitly asks to add something to their todos — don't be \
        presumptuous.

        Pass `tasks` as a JSON array of one or more task objects. Each object:
        - `"title"` (required, non-empty): the task text.
        - `"priority"` (optional): one of `"urgent"`, `"high"`, `"normal"`. \
        Defaults to `"normal"`. These are the user's own ordering, not a \
        severity score — mirror what they say.
        - `"dueAt"` (optional): an ISO-8601 date, either date-only \
        (`"2026-06-10"`, interpreted as UTC) or a full timestamp \
        (`"2026-06-10T09:00:00Z"`). Resolve relative dates ("next Tuesday") \
        against the current date before calling.
        - `"notes"` (optional): free-text detail.

        Example: \
        [{"title":"Buy milk"},{"title":"Pay rent","priority":"high","dueAt":"2026-06-10"}]

        The whole batch is created together: if any item is invalid, nothing \
        is created and you get an error to fix and retry.
        """,
        category: .mutation,
        parameters: [
            LLMToolParameter(
                name: "tasks",
                type: .string,
                description: "JSON array of task objects to create. Each requires a non-empty 'title'; optional 'priority' ('urgent'|'high'|'normal'), 'dueAt' (ISO-8601), and 'notes'.",
                isRequired: true
            ),
        ],
        appletId: TodoCreateTool.appletID,
        displayName: "Create tasks",
        summary: "Adds one or more tasks to your Todo list."
    )

    /// Build a `ToolRegistration` ready to hand to `ToolRegistry.register(_:)`.
    /// The composition root calls this in the SuperOS bootstrap.
    public static func registration(
        repository: any TaskRepository,
        clock: any Clock = SystemClock(),
        ids: any IDGenerator = UUIDGenerator(),
        isEnabled: Bool = true
    ) -> ToolRegistration {
        ToolRegistration(
            tool: descriptor,
            execution: .local(TodoCreateTool(repository: repository, clock: clock, ids: ids)),
            isEnabled: isEnabled
        )
    }

    public func execute(input: [String: JSONValue]) async throws -> ToolResult {
        let specs: [ValidatedTask]
        do {
            specs = try Self.validate(input: input)
        } catch let validation as ValidationError {
            return Self.errorResult(validation.message)
        }

        // Validation already passed for every item; build each record from the
        // same `now`, then write.
        let now = clock.now()
        var created: [TaskRecord] = []
        created.reserveCapacity(specs.count)
        do {
            for (index, spec) in specs.enumerated() {
                let record = TaskRecord(
                    id: ids.nextID(),
                    title: spec.title,
                    // Timestamp-based sort, offset per item so a batch keeps a
                    // stable relative order (matches `saveDraft`'s convention).
                    sortOrder: now.timeIntervalSince1970 + Double(index),
                    createdAt: now,
                    updatedAt: now,
                    notes: spec.notes,
                    priority: spec.priority,
                    state: .open,
                    dueAt: spec.dueAt
                )
                try await repository.save(record)
                created.append(record)
            }
        } catch {
            // Saves aren't one transaction, so rows written before this
            // failure stay committed. Report the count so an LLM retry is less
            // likely to duplicate the ones that already succeeded.
            return Self.errorResult(
                "Created \(created.count) of \(specs.count) task(s) before a write error: \(error.localizedDescription)"
            )
        }

        let titles = created.map(\.title).joined(separator: ", ")
        let noun = created.count == 1 ? "task" : "tasks"
        return ToolResult(
            toolID: TodoCreateTool.toolID,
            content: "Created \(created.count) \(noun): \(titles).",
            isError: false,
            artifacts: created.map { ToolResult.Artifact(type: "task", id: $0.id) }
        )
    }

    // MARK: - Validation

    private struct ValidatedTask {
        let title: String
        let priority: TaskPriority
        let dueAt: Date?
        let notes: String
    }

    private struct ValidationError: Error {
        let message: String
    }

    /// One task object as it arrives in the JSON payload. All fields but
    /// `title` are optional; `priority`/`dueAt` are strings parsed downstream
    /// so an unknown value yields a remediation message, not a decode failure.
    private struct TaskSpec: Decodable {
        let title: String
        let priority: String?
        let dueAt: String?
        let notes: String?
    }

    private static func validate(input: [String: JSONValue]) throws -> [ValidatedTask] {
        guard case .string(let raw) = input["tasks"] else {
            throw ValidationError(message: "`tasks` is required and must be a JSON array string.")
        }
        let specs: [TaskSpec]
        do {
            specs = try JSONDecoder().decode([TaskSpec].self, from: Data(raw.utf8))
        } catch {
            throw ValidationError(message: "`tasks` must be a JSON array of task objects, e.g. [{\"title\":\"Buy milk\"}].")
        }
        guard !specs.isEmpty else {
            throw ValidationError(message: "`tasks` must contain at least one task.")
        }

        return try specs.map { spec in
            let title = spec.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw ValidationError(message: "Every task needs a non-empty `title`.")
            }
            let priority = try parsePriority(spec.priority)
            let dueAt = try parseDueAt(spec.dueAt)
            return ValidatedTask(title: title, priority: priority, dueAt: dueAt, notes: spec.notes ?? "")
        }
    }

    private static func parsePriority(_ raw: String?) throws -> TaskPriority {
        guard let raw else { return .normal }
        switch raw.lowercased() {
        case "urgent": return .urgent
        case "high": return .high
        case "normal": return .normal
        default:
            throw ValidationError(message: "Unknown priority '\(raw)'. Use 'urgent', 'high', or 'normal'.")
        }
    }

    private static func parseDueAt(_ raw: String?) throws -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = ISO8601DateFormatter().date(from: raw) {
            return date
        }
        // Date-only (`yyyy-MM-dd`) fallback, pinned to UTC so a bare date
        // lands on UTC midnight rather than the device's local midnight.
        // Formatters aren't `Sendable`, so build one per call rather than
        // sharing a static instance across concurrency domains.
        let dateOnly = DateFormatter()
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = TimeZone(identifier: "UTC")
        dateOnly.dateFormat = "yyyy-MM-dd"
        if let date = dateOnly.date(from: raw) {
            return date
        }
        throw ValidationError(message: "Couldn't parse dueAt '\(raw)'. Use an ISO-8601 date like '2026-06-10' or '2026-06-10T09:00:00Z'.")
    }

    private static func errorResult(_ message: String) -> ToolResult {
        ToolResult(toolID: TodoCreateTool.toolID, content: message, isError: true)
    }
}
