import Core
import Foundation
import Testing
@testable import Todo

/// Tests for `TodoScreenViewModel`: load hydration, create / edit save
/// round-trips, state cycling, delete, and case-insensitive label creation.
/// Each test runs against an in-memory GRDB database with a `FixedClock`
/// and `DeterministicIDGenerator` so timestamps and ids stay deterministic.
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

    private func task(_ id: String, title: String = "x", priority: TaskPriority = .normal, state: TaskState = .open) -> TaskRecord {
        TaskRecord(
            id: id, title: title,
            sortOrder: 0, createdAt: now, updatedAt: now,
            priority: priority, state: state
        )
    }

    @Test func loadHydratesTasksAndLabels() async throws {
        let (viewModel, taskRepo, labelRepo, joinRepo) = try makeViewModel()
        try await labelRepo.save(LabelRecord(id: "L1", name: "Work", hue: 200, createdAt: now, updatedAt: now))
        try await taskRepo.save(task("T1", title: "buy", priority: .urgent))
        try await joinRepo.setLabels(taskId: "T1", labelIds: ["L1"], at: now)

        await viewModel.load()
        #expect(viewModel.tasks.count == 1)
        #expect(viewModel.tasks.first?.labels.first?.name == "Work")
        #expect(viewModel.labels.count == 1)
        #expect(viewModel.counts.open == 1)
    }

    @Test func saveDraftAsCreateInsertsNewTask() async throws {
        let (viewModel, _, _, _) = try makeViewModel()
        viewModel.beginCreate()
        viewModel.draft?.title = "Buy milk"
        viewModel.draft?.priority = .high
        await viewModel.saveDraft()

        #expect(viewModel.draft == nil)
        #expect(viewModel.toast?.text == "Created")
        await viewModel.load()
        #expect(viewModel.tasks.count == 1)
        #expect(viewModel.tasks.first?.task.title == "Buy milk")
        #expect(viewModel.tasks.first?.task.priority == .high)
    }

    @Test func saveDraftAsEditUpdatesExistingTask() async throws {
        let (viewModel, taskRepo, _, _) = try makeViewModel()
        try await taskRepo.save(task("T1", title: "old"))
        await viewModel.load()
        viewModel.beginEdit(viewModel.tasks[0])
        viewModel.draft?.title = "new"
        await viewModel.saveDraft()

        #expect(viewModel.toast?.text == "Saved")
        await viewModel.load()
        #expect(viewModel.tasks.count == 1)
        #expect(viewModel.tasks.first?.task.title == "new")
    }

    @Test func saveDraftWithBlankTitleNoOps() async throws {
        let (viewModel, _, _, _) = try makeViewModel()
        viewModel.beginCreate()
        viewModel.draft?.title = "   "
        await viewModel.saveDraft()
        await viewModel.load()
        #expect(viewModel.tasks.isEmpty)
    }

    @Test func cycleStateFlipsOpenToDone() async throws {
        let (viewModel, taskRepo, _, _) = try makeViewModel()
        try await taskRepo.save(task("T1"))
        await viewModel.load()
        await viewModel.cycleState(viewModel.tasks[0])
        #expect(viewModel.tasks.first?.task.state == .done)
        #expect(viewModel.toast?.text == "Completed")
    }

    @Test func cycleStateFlipsDoneBackToOpen() async throws {
        let (viewModel, taskRepo, _, _) = try makeViewModel()
        try await taskRepo.save(task("T1", state: .done))
        await viewModel.load()
        await viewModel.cycleState(viewModel.tasks[0])
        #expect(viewModel.tasks.first?.task.state == .open)
        #expect(viewModel.toast?.text == "Reopened")
    }

    @Test func deleteRemovesTaskAndItsLabelJoins() async throws {
        let (viewModel, taskRepo, labelRepo, joinRepo) = try makeViewModel()
        try await taskRepo.save(task("T1"))
        try await labelRepo.save(LabelRecord(id: "L1", name: "Work", hue: 200, createdAt: now, updatedAt: now))
        try await joinRepo.setLabels(taskId: "T1", labelIds: ["L1"], at: now)
        await viewModel.load()
        await viewModel.delete(taskID: "T1")

        #expect(viewModel.tasks.isEmpty)
        #expect(try await joinRepo.labels(forTaskId: "T1").isEmpty)
    }

    @Test func ensureLabelReturnsExistingMatchCaseInsensitive() async throws {
        let (viewModel, _, labelRepo, _) = try makeViewModel()
        try await labelRepo.save(LabelRecord(id: "L1", name: "Work", hue: 200, createdAt: now, updatedAt: now))
        await viewModel.load()
        let id = await viewModel.ensureLabel(name: "work")
        #expect(id == "L1")
        #expect(viewModel.labels.count == 1)
    }

    @Test func ensureLabelCreatesWhenNoMatch() async throws {
        let (viewModel, _, _, _) = try makeViewModel()
        await viewModel.load()
        let id = await viewModel.ensureLabel(name: "Travel")
        #expect(id != nil)
        #expect(viewModel.labels.map(\.name).contains("Travel"))
    }
}
