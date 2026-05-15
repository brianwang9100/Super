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

    private func calendar(zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
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

    @Test func visibleAppliesTheActiveFilter() async throws {
        let (viewModel, taskRepo, _, _) = try makeViewModel()
        try await taskRepo.save(task("open", state: .open))
        try await taskRepo.save(task("done", state: .done))
        await viewModel.load()
        viewModel.filter = TodoFilter(state: .done)
        #expect(viewModel.visible.map(\.id) == ["done"])
    }

    @Test func countsTallyByState() async throws {
        let (viewModel, taskRepo, _, _) = try makeViewModel()
        try await taskRepo.save(task("a", state: .open))
        try await taskRepo.save(task("b", state: .done))
        try await taskRepo.save(task("c", state: .cancelled))
        await viewModel.load()
        let counts = viewModel.counts
        #expect(counts.open == 1)
        #expect(counts.done == 1)
        #expect(counts.cancelled == 1)
    }

    @Test func filterSummaryDescribesActiveFilter() async throws {
        let (viewModel, _, _, _) = try makeViewModel()
        viewModel.filter = TodoFilter(sort: .newest, state: .all)
        #expect(viewModel.filterSummary == "All · by newest")
    }

    /// The view model must pass its injected `calendar` through to
    /// `groupTasks` — otherwise "due today" silently follows the device
    /// time zone. Tokyo (UTC+9) and UTC disagree on the day of `due`, so
    /// the same task lands in different groups under each calendar.
    @Test func groupsUseTheInjectedCalendarNotTheDeviceZone() async throws {
        let utc = calendar(zone: "UTC")
        let fixedNow = utc.date(from: DateComponents(year: 2023, month: 11, day: 14, hour: 20))!
        let due = utc.date(from: DateComponents(year: 2023, month: 11, day: 15, hour: 2))!

        func firstGroupTitle(using calendar: Calendar) async throws -> String? {
            let db = try TodoDatabase.makeInMemory()
            let taskRepo = GRDBTaskRepository(database: db)
            let viewModel = TodoScreenViewModel(
                taskRepository: taskRepo,
                labelRepository: GRDBLabelRepository(database: db),
                joinRepository: GRDBTaskLabelRepository(database: db),
                clock: FixedClock(fixedNow),
                ids: DeterministicIDGenerator(prefix: "id-"),
                calendar: calendar
            )
            try await taskRepo.save(TaskRecord(
                id: "T1", title: "x",
                sortOrder: 0, createdAt: fixedNow, updatedAt: fixedNow,
                dueAt: due
            ))
            await viewModel.load()
            viewModel.filter = TodoFilter(sort: .dueDate, state: .open)
            return viewModel.groups.first?.title
        }

        #expect(try await firstGroupTitle(using: calendar(zone: "Asia/Tokyo")) == "Today")
        #expect(try await firstGroupTitle(using: utc) == "Upcoming")
    }

    @Test func saveDraftAsEditPreservesSortOrderAndCreatedAt() async throws {
        let (viewModel, taskRepo, _, _) = try makeViewModel()
        let createdAt = now.addingTimeInterval(-86_400)
        try await taskRepo.save(TaskRecord(
            id: "T1", title: "old",
            sortOrder: 7, createdAt: createdAt, updatedAt: createdAt
        ))
        await viewModel.load()
        viewModel.beginEdit(viewModel.tasks[0])
        viewModel.draft?.title = "new"
        await viewModel.saveDraft()

        let saved = try await taskRepo.fetch(id: "T1")
        #expect(saved?.title == "new")
        #expect(saved?.sortOrder == 7)
        #expect(saved?.createdAt == createdAt)
        #expect(saved?.updatedAt == now)
    }
}
