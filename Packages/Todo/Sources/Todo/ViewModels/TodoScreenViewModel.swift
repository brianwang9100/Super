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

/// Screen-level UI state for `TodoScreen`: the active filter, the
/// create/edit draft, and the toast — plus the task/label mutation methods.
///
/// The view model deliberately does **not** own the task or label lists.
/// Those are bound reactively in the view via `@Query(ActiveTasksRequest())`
/// / `@Query(ActiveLabelsRequest())` so edits from other applets (e.g. Chat
/// creating a task) flow into the UI without a manual reload. Mutations
/// here just write through the repositories; the observation refreshes the
/// view.
@Observable
@MainActor
public final class TodoScreenViewModel {
    /// Whether a create or edit draft is open.
    public enum DraftMode: Sendable { case create, edit }

    // User-driven UI state
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

    /// Reentrancy guard for `saveDraft()`. `saveDraft` suspends at `await`
    /// points; without this a double-tap of Save would let a second call
    /// pass the entry checks and mint a second task. Not observed — it is
    /// internal control state, not UI state.
    @ObservationIgnored private var isSaving = false

    /// Calendar for the screen's "due today" grouping. Injected so the
    /// list stays deterministic across time zones and under snapshot test.
    public let calendar: Calendar

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

    /// Current instant from the injected clock — read by the screen for
    /// filtering and grouping.
    public var now: Date { clock.now() }

    // MARK: Mutators

    /// Toggle a row's state from the inline state-box tap: an `open` task
    /// becomes `done`; a `done` or `cancelled` task becomes `open`.
    public func cycleState(_ row: TaskWithLabels) async {
        let next: TaskState = row.task.state == .open ? .done : .open
        await setState(taskID: row.task.id, to: next)
    }

    /// Set a task's state. The reactive query refreshes the row.
    public func setState(taskID: String, to newState: TaskState) async {
        do {
            try await taskRepository.setState(id: taskID, state: newState, at: clock.now())
            switch newState {
            case .done:      flash("Completed")
            case .cancelled: flash("Cancelled")
            case .open:      flash("Reopened")
            }
        } catch {
            flash("Couldn't update task")
        }
    }

    /// Hard-delete a task. The join rows cascade away with it, and the
    /// reactive query drops the row.
    public func delete(taskID: String) async {
        do {
            try await taskRepository.hardDelete(id: taskID)
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

    // MARK: Field-scoped draft edits
    //
    // One mutator per editable field, each backing a per-field two-way
    // binding in `TodoTaskEditorSheet`. Every mutator reads the *current*
    // draft and rewrites only its own field, so a buffered or late commit
    // from one editor control can never carry a stale value for a *different*
    // field. (The editor's two `TextField(axis: .vertical)` fields commit
    // their text late; routing every field through a single whole-`TaskDraft`
    // binding previously let such a late commit silently revert a priority
    // the user had changed in between — the bug this split fixes.)
    //
    // Each is also a no-op once the draft has been cleared by `saveDraft()`
    // or `cancelDraft()`: as the editor sheet animates away its fields can
    // still commit a final value, and without the `nil` guard that late write
    // would resurrect a dismissed editor as a blank task.

    /// Set the open draft's title; no-op when no draft is open.
    public func setDraftTitle(_ title: String) {
        guard var draft else { return }
        draft.title = title
        self.draft = draft
    }

    /// Set the open draft's notes; no-op when no draft is open.
    public func setDraftNotes(_ notes: String) {
        guard var draft else { return }
        draft.notes = notes
        self.draft = draft
    }

    /// Set the open draft's priority; no-op when no draft is open.
    public func setDraftPriority(_ priority: TaskPriority) {
        guard var draft else { return }
        draft.priority = priority
        self.draft = draft
    }

    /// Set the open draft's due date (or clear it); no-op when no draft is open.
    public func setDraftDueAt(_ dueAt: Date?) {
        guard var draft else { return }
        draft.dueAt = dueAt
        self.draft = draft
    }

    /// Set the open draft's label ids; no-op when no draft is open.
    public func setDraftLabelIds(_ labelIds: [String]) {
        guard var draft else { return }
        draft.labelIds = labelIds
        self.draft = draft
    }

    /// Set the open draft's state; no-op when no draft is open.
    public func setDraftState(_ state: TaskState) {
        guard var draft else { return }
        draft.state = state
        self.draft = draft
    }

    /// Persist the open draft (create or edit) and its label set. A draft
    /// with a blank title is a no-op so an empty create can't slip through.
    public func saveDraft() async {
        guard let draft else { return }
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Reentrancy guard: a second `saveDraft()` dispatched while the
        // first is suspended at an `await` would otherwise pass the checks
        // above and mint a duplicate task on a Save double-tap.
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        // Capture before the `await`s below: a `beginCreate()` / `beginEdit()`
        // dispatched between suspension points could otherwise flip the mode
        // out from under the success toast.
        let mode = draftMode
        let now = clock.now()
        let id = draft.id ?? ids.nextID()
        do {
            // An edit preserves the row's original `sortOrder` / `createdAt`;
            // a new task sorts after existing rows by using `now` as its
            // monotonic `sortOrder`.
            let existing = draft.id == nil ? nil : try await taskRepository.fetch(id: id)
            let record = TaskRecord(
                id: id,
                title: draft.title,
                sortOrder: existing?.sortOrder ?? now.timeIntervalSince1970,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now,
                notes: draft.notes,
                priority: draft.priority,
                state: draft.state,
                dueAt: draft.dueAt
            )
            try await taskRepository.save(record)
            try await joinRepository.setLabels(taskId: id, labelIds: draft.labelIds, at: now)
            // Only clear the draft we just persisted. If the user opened a
            // different draft at an `await` suspension point above, leave
            // it intact rather than discarding their input. Value equality
            // (not an `id` check) is used because two create drafts both
            // carry `id == nil` and must still be told apart.
            if self.draft == draft {
                self.draft = nil
            }
            flash(mode == .create ? "Created" : "Saved")
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
            let activeLabels = try await labelRepository.listActive()
            let hue = LabelHuePalette.nextHue(
                usedHues: Set(activeLabels.map(\.hue)),
                existingCount: activeLabels.count
            )
            // Re-check after the suspension points above — a concurrent
            // call (e.g. a double tap) may have created the label, and the
            // partial unique index would otherwise reject the second save.
            if let raced = try await labelRepository.findActive(name: trimmed) {
                return raced.id
            }
            let now = clock.now()
            let record = LabelRecord(
                id: ids.nextID(),
                name: trimmed,
                hue: hue,
                createdAt: now,
                updatedAt: now
            )
            try await labelRepository.save(record)
            flash("Created label \"\(trimmed)\"")
            return record.id
        } catch {
            // The save may have failed because a concurrent call created
            // the same label (the partial unique index rejects the dupe).
            // If so, return that label's id rather than reporting failure.
            if let raced = try? await labelRepository.findActive(name: trimmed) {
                return raced.id
            }
            flash("Couldn't create label")
            return nil
        }
    }

    /// Clear the active toast (called by the view after its display delay).
    public func dismissToast() {
        toast = nil
    }

    // MARK: Internals

    private func flash(_ text: String) {
        toast = TodoToastMessage(id: ids.nextID(), text: text)
    }
}
