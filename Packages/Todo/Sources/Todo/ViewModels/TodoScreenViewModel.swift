import Core
import Foundation
import Observation

/// In-flight editor draft. Created when the user taps `＋` (create) or taps
/// a row (edit). `id == nil` means "new" — `saveDraft()` mints one.
public struct TaskDraft: Sendable, Equatable {
    public var id: String?
    public var title: String
    public var notes: String
    public var priority: TaskPriority
    public var dueAt: Date?
    public var state: TaskState
    /// Ordered because the tag picker shows chips in the order the user
    /// added them; the join table itself is unordered.
    public var labelIds: [String]

    public init(
        id: String? = nil,
        title: String = "",
        notes: String = "",
        priority: TaskPriority = .normal,
        dueAt: Date? = nil,
        state: TaskState = .open,
        labelIds: [String] = []
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.priority = priority
        self.dueAt = dueAt
        self.state = state
        self.labelIds = labelIds
    }

    /// A blank draft for the create flow.
    public static let empty = TaskDraft()
}

/// One-shot user-facing transient (the design's `flash()` toast). The view
/// layer clears it after a short delay; the view model only emits it.
public struct TodoToastMessage: Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// Screen-level state for `TodoScreen`: the loaded tasks and labels, the
/// active filter, the create/edit draft, and the toast. Persistence is
/// delegated to the three injected repositories; filtering and grouping
/// run through the pure `applyFilter` / `groupTasks` functions.
@Observable
@MainActor
public final class TodoScreenViewModel {
    /// Whether a create or edit draft is open.
    public enum DraftMode: Sendable { case create, edit }

    // Loaded data
    public private(set) var tasks: [TaskWithLabels] = []
    public private(set) var labels: [LabelRecord] = []
    public private(set) var isLoading: Bool = false
    public private(set) var loadError: String?

    // User-driven state
    public var filter: TodoFilter = .defaults
    public var draft: TaskDraft?
    public var draftMode: DraftMode = .create
    public var toast: TodoToastMessage?

    // Injected
    private let taskRepository: any TaskRepository
    private let labelRepository: any LabelRepository
    private let joinRepository: any TaskLabelRepository
    private let clock: any Clock
    private let ids: any IDGenerator
    /// Calendar used for "due today" grouping. Injected (rather than read
    /// from `Calendar.current` inside `applyFilter` / `groupTasks`) so the
    /// list stays deterministic across time zones and under test.
    private let calendar: Calendar

    public init(
        taskRepository: any TaskRepository,
        labelRepository: any LabelRepository,
        joinRepository: any TaskLabelRepository,
        clock: any Clock,
        ids: any IDGenerator,
        calendar: Calendar = .current
    ) {
        self.taskRepository = taskRepository
        self.labelRepository = labelRepository
        self.joinRepository = joinRepository
        self.clock = clock
        self.ids = ids
        self.calendar = calendar
    }

    // MARK: Load

    /// Hydrate `tasks` and `labels` from the repositories. Reads the task
    /// list and label list concurrently, then bulk-loads every task's
    /// labels in one query.
    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let taskRows = taskRepository.listActive()
            async let labelRows = labelRepository.listActive()
            let (rawTasks, labelsList) = try await (taskRows, labelRows)
            let bulkLabels = try await joinRepository.labels(forTaskIds: rawTasks.map(\.id))
            tasks = rawTasks.map { TaskWithLabels(task: $0, labels: bulkLabels[$0.id] ?? []) }
            labels = labelsList
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Derived

    /// Tasks after the active filter, before grouping.
    public var visible: [TaskWithLabels] {
        applyFilter(filter, to: tasks, now: clock.now(), calendar: calendar)
    }

    /// The visible tasks split into the design's grouped sections. Captures
    /// `now` once so the filter pass and the grouping pass agree on "today"
    /// — a task due at the instant of render can't land in two passes with
    /// different timestamps.
    public var groups: [TodoListGroup] {
        let now = clock.now()
        let filtered = applyFilter(filter, to: tasks, now: now, calendar: calendar)
        return groupTasks(filtered, filter: filter, now: now, calendar: calendar)
    }

    /// Label id → record, for resolving filter / chip lookups.
    public var labelLookup: [String: LabelRecord] {
        Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })
    }

    /// One-line summary string for the filter pill.
    public var filterSummary: String {
        describe(filter, labelLookup: labelLookup)
    }

    /// Task counts by state, across the full unfiltered list.
    public var counts: (open: Int, done: Int, cancelled: Int) {
        var open = 0, done = 0, cancelled = 0
        for row in tasks {
            switch row.task.state {
            case .open:      open += 1
            case .done:      done += 1
            case .cancelled: cancelled += 1
            }
        }
        return (open, done, cancelled)
    }

    // MARK: Mutators

    /// Toggle a row's state from the inline state-box tap: an `open` task
    /// becomes `done`; a `done` or `cancelled` task becomes `open`.
    public func cycleState(_ row: TaskWithLabels) async {
        let next: TaskState = row.task.state == .open ? .done : .open
        await setState(taskID: row.task.id, to: next)
    }

    /// Set a task's state and refresh its row.
    public func setState(taskID: String, to newState: TaskState) async {
        do {
            try await taskRepository.setState(id: taskID, state: newState, at: clock.now())
            await reloadTask(taskID)
            switch newState {
            case .done:      flash("Completed")
            case .cancelled: flash("Cancelled")
            case .open:      flash("Reopened")
            }
        } catch {
            flash("Couldn't update task")
        }
    }

    /// Hard-delete a task. The join rows cascade away with it.
    public func delete(taskID: String) async {
        do {
            try await taskRepository.hardDelete(id: taskID)
            tasks.removeAll { $0.task.id == taskID }
            flash("Deleted")
        } catch {
            flash("Couldn't delete task")
        }
    }

    /// Open a blank create draft.
    public func beginCreate() {
        draft = .empty
        draftMode = .create
    }

    /// Open an edit draft pre-filled from `row`.
    public func beginEdit(_ row: TaskWithLabels) {
        draft = TaskDraft(
            id: row.task.id,
            title: row.task.title,
            notes: row.task.notes,
            priority: row.task.priority,
            dueAt: row.task.dueAt,
            state: row.task.state,
            labelIds: row.labels.map(\.id)
        )
        draftMode = .edit
    }

    /// Discard the open draft.
    public func cancelDraft() {
        draft = nil
    }

    /// Persist the open draft (create or edit) and its label set. A draft
    /// with a blank title is a no-op so an empty create can't slip through.
    public func saveDraft() async {
        guard let draft else { return }
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let now = clock.now()
        let id = draft.id ?? ids.nextID()
        // New tasks land at the bottom of the manual order; edits keep the
        // existing row's `sortOrder` and `createdAt`.
        let existing = tasks.first(where: { $0.task.id == id })?.task
        let sortOrder = existing?.sortOrder ?? ((tasks.map(\.task.sortOrder).max() ?? 0) + 1)
        let record = TaskRecord(
            id: id,
            title: draft.title,
            sortOrder: sortOrder,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            notes: draft.notes,
            priority: draft.priority,
            state: draft.state,
            dueAt: draft.dueAt
        )
        do {
            try await taskRepository.save(record)
            try await joinRepository.setLabels(taskId: id, labelIds: draft.labelIds, at: now)
            await reloadTask(id)
            self.draft = nil
            flash(draftMode == .create ? "Created" : "Saved")
        } catch {
            flash("Couldn't save task")
        }
    }

    /// Create-or-fetch a label by name (case-insensitive). Returns the
    /// canonical id so the caller can append it to a draft.
    public func ensureLabel(name: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            if let existing = try await labelRepository.findActive(name: trimmed) {
                return existing.id
            }
            let now = clock.now()
            let hue = LabelHuePalette.nextHue(
                usedHues: Set(labels.map(\.hue)),
                existingCount: labels.count
            )
            let record = LabelRecord(
                id: ids.nextID(),
                name: trimmed,
                hue: hue,
                createdAt: now,
                updatedAt: now
            )
            try await labelRepository.save(record)
            labels.append(record)
            labels.sort { $0.name.lowercased() < $1.name.lowercased() }
            flash("Created label \"\(trimmed)\"")
            return record.id
        } catch {
            flash("Couldn't create label")
            return nil
        }
    }

    /// Clear the active toast (called by the view after its display delay).
    public func dismissToast() {
        toast = nil
    }

    // MARK: Internals

    /// Re-fetch one task plus its labels and splice it back into `tasks`.
    /// A best-effort refresh — on failure the next full `load()` reconciles.
    private func reloadTask(_ id: String) async {
        do {
            guard let row = try await taskRepository.fetch(id: id) else {
                tasks.removeAll { $0.task.id == id }
                return
            }
            let labelRows = try await joinRepository.labels(forTaskId: id)
            let merged = TaskWithLabels(task: row, labels: labelRows)
            if let index = tasks.firstIndex(where: { $0.task.id == id }) {
                tasks[index] = merged
            } else {
                tasks.append(merged)
            }
        } catch {
            // Best-effort; the next full `load()` reconciles.
        }
    }

    private func flash(_ text: String) {
        toast = TodoToastMessage(id: ids.nextID(), text: text)
    }
}
