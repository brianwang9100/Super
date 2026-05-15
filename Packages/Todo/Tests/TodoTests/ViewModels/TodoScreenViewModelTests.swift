import Core
import Foundation
import Testing
@testable import Todo

/// Tests for `TodoScreenViewModel`: the create/edit save round-trips, state
/// cycling, delete, and case-insensitive label creation. The view model
/// owns no task/label list (those bind reactively in the view), so each
/// test asserts against the repositories directly. Runs against an
/// in-memory GRDB database with a `FixedClock` and `DeterministicIDGenerator`.
@Suite("TodoScreenViewModel")
@MainActor
struct TodoScreenViewModelTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeViewModel() throws -> (
        TodoScreenViewModel,
        GRDBTaskRepository,
        GRDBLabelRepository,
        GRDBTaskLabelRepository
    ) {
        let db = try TodoDatabase.makeInMemory()
        let taskRepo = GRDBTaskRepository(database: db)
        let labelRepo = GRDBLabelRepository(database: db)
        let joinRepo = GRDBTaskLabelRepository(database: db)
        let viewModel = TodoScreenViewModel(
            taskRepository: taskRepo,
            labelRepository: labelRepo,
            joinRepository: joinRepo,
            clock: FixedClock(now),
            ids: DeterministicIDGenerator(prefix: "id-")
        )
        return (viewModel, taskRepo, labelRepo, joinRepo)
    }

    private func task(_ id: String, title: String = "x", state: TaskState = .open) -> TaskRecord {
        TaskRecord(
            id: id, title: title,
            sortOrder: 0, createdAt: now, updatedAt: now,
            priority: .normal, state: state
        )
    }

    @Test func saveDraftAsCreateInsertsNewTask() async throws {
        let (viewModel, taskRepo, _, _) = try makeViewModel()
        viewModel.beginCreate()
        viewModel.draft?.title = "Buy milk"
        viewModel.draft?.priority = .high
        await viewModel.saveDraft()

        #expect(viewModel.draft == nil)
        #expect(viewModel.toast?.text == "Created")
        let active = try await taskRepo.listActive()
        #expect(active.count == 1)
        #expect(active.first?.title == "Buy milk")
        #expect(active.first?.priority == .high)
    }

    @Test func saveDraftAsEditUpdatesExistingTask() async throws {
        let (viewModel, taskRepo, _, _) = try makeViewModel()
        try await taskRepo.save(task("T1", title: "old"))
        viewModel.beginEdit(TaskWithLabels(task: task("T1", title: "old"), labels: []))
        viewModel.draft?.title = "new"
        await viewModel.saveDraft()

        #expect(viewModel.toast?.text == "Saved")
        #expect(try await taskRepo.fetch(id: "T1")?.title == "new")
    }

    @Test func saveDraftAsEditPreservesSortOrderAndCreatedAt() async throws {
        let (viewModel, taskRepo, _, _) = try makeViewModel()
        let createdAt = now.addingTimeInterval(-86_400)
        let original = TaskRecord(
            id: "T1", title: "old",
            sortOrder: 7, createdAt: createdAt, updatedAt: createdAt
        )
        try await taskRepo.save(original)
        viewModel.beginEdit(TaskWithLabels(task: original, labels: []))
        viewModel.draft?.title = "new"
        await viewModel.saveDraft()

        let saved = try await taskRepo.fetch(id: "T1")
        #expect(saved?.title == "new")
        #expect(saved?.sortOrder == 7)
        #expect(saved?.createdAt == createdAt)
        #expect(saved?.updatedAt == now)
    }

    @Test func saveDraftIgnoresConcurrentDoubleTap() async throws {
        let (viewModel, taskRepo, _, _) = try makeViewModel()
        viewModel.beginCreate()
        viewModel.draft?.title = "Buy milk"
        // Two saves dispatched together — a Save double-tap. The reentrancy
        // guard must let only one through, so exactly one task is created.
        async let first: Void = viewModel.saveDraft()
        async let second: Void = viewModel.saveDraft()
        _ = await (first, second)
        #expect(try await taskRepo.listActive().count == 1)
    }

    @Test func saveDraftWithBlankTitleNoOps() async throws {
        let (viewModel, taskRepo, _, _) = try makeViewModel()
        viewModel.beginCreate()
        viewModel.draft?.title = "   "
        await viewModel.saveDraft()
        #expect(try await taskRepo.listActive().isEmpty)
    }

    @Test func saveDraftAttachesLabelsToTheTask() async throws {
        let (viewModel, taskRepo, labelRepo, joinRepo) = try makeViewModel()
        try await labelRepo.save(LabelRecord(id: "L1", name: "Work", hue: 200, createdAt: now, updatedAt: now))
        viewModel.beginCreate()
        viewModel.draft?.title = "Task with label"
        viewModel.draft?.labelIds = ["L1"]
        await viewModel.saveDraft()

        let createdID = try #require(try await taskRepo.listActive().first?.id)
        let labels = try await joinRepo.labels(forTaskId: createdID)
        #expect(labels.map(\.id) == ["L1"])
    }

    @Test func cycleStateFlipsOpenToDone() async throws {
        let (viewModel, taskRepo, _, _) = try makeViewModel()
        try await taskRepo.save(task("T1", state: .open))
        await viewModel.cycleState(TaskWithLabels(task: task("T1", state: .open), labels: []))
        #expect(try await taskRepo.fetch(id: "T1")?.state == .done)
        #expect(viewModel.toast?.text == "Completed")
    }

    @Test func cycleStateFlipsDoneBackToOpen() async throws {
        let (viewModel, taskRepo, _, _) = try makeViewModel()
        try await taskRepo.save(task("T1", state: .done))
        await viewModel.cycleState(TaskWithLabels(task: task("T1", state: .done), labels: []))
        #expect(try await taskRepo.fetch(id: "T1")?.state == .open)
        #expect(viewModel.toast?.text == "Reopened")
    }

    @Test func cycleStateFlipsCancelledToOpen() async throws {
        let (viewModel, taskRepo, _, _) = try makeViewModel()
        try await taskRepo.save(task("T1", state: .cancelled))
        await viewModel.cycleState(TaskWithLabels(task: task("T1", state: .cancelled), labels: []))
        #expect(try await taskRepo.fetch(id: "T1")?.state == .open)
        #expect(viewModel.toast?.text == "Reopened")
    }

    @Test func deleteRemovesTask() async throws {
        let (viewModel, taskRepo, _, _) = try makeViewModel()
        try await taskRepo.save(task("T1"))
        await viewModel.delete(taskID: "T1")
        #expect(try await taskRepo.fetch(id: "T1") == nil)
        #expect(viewModel.toast?.text == "Deleted")
    }

    @Test func ensureLabelReturnsExistingMatchCaseInsensitive() async throws {
        let (viewModel, _, labelRepo, _) = try makeViewModel()
        try await labelRepo.save(LabelRecord(id: "L1", name: "Work", hue: 200, createdAt: now, updatedAt: now))
        let id = await viewModel.ensureLabel(name: "work")
        #expect(id == "L1")
        #expect(try await labelRepo.listActive().count == 1)
    }

    @Test func ensureLabelCreatesWhenNoMatch() async throws {
        let (viewModel, _, labelRepo, _) = try makeViewModel()
        let id = await viewModel.ensureLabel(name: "Travel")
        #expect(id != nil)
        #expect(try await labelRepo.findActive(name: "travel") != nil)
    }
}
