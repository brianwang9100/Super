import Core
import Foundation
import Testing
@testable import Todo

/// Tests for `TodoCreateTool` — the `todo.create` LLM tool that parses a
/// JSON-array `tasks` payload and inserts one or more `TaskRecord`s. Covers
/// batch creation, per-item field parsing (priority / dueAt / notes),
/// all-or-nothing validation, and the registration + artifact contracts.
@Suite("TodoCreateTool")
struct TodoCreateToolTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTool(
        ids: DeterministicIDGenerator = DeterministicIDGenerator(prefix: "task-")
    ) throws -> (TodoCreateTool, GRDBTaskRepository) {
        let database = try TodoDatabase.makeInMemory()
        let repository = GRDBTaskRepository(database: database)
        let tool = TodoCreateTool(repository: repository, clock: FixedClock(t0), ids: ids)
        return (tool, repository)
    }

    private func run(_ tool: TodoCreateTool, _ json: String) async throws -> ToolResult {
        try await tool.execute(input: ["tasks": .string(json)])
    }

    // MARK: - Creation

    @Test("creates a single task with defaults")
    func createsSingleTask() async throws {
        let (tool, repo) = try makeTool()
        let result = try await run(tool, #"[{"title":"Buy milk"}]"#)

        #expect(result.isError == false)
        let tasks = try await repo.listActive()
        #expect(tasks.count == 1)
        let task = try #require(tasks.first)
        #expect(task.title == "Buy milk")
        #expect(task.priority == .normal)
        #expect(task.state == .open)
        #expect(task.notes == "")
        #expect(task.dueAt == nil)
        #expect(task.createdAt == t0)
        #expect(task.updatedAt == t0)
    }

    @Test("creates multiple tasks from one call")
    func createsMultipleTasks() async throws {
        let (tool, repo) = try makeTool()
        let result = try await run(tool, #"[{"title":"Milk"},{"title":"Eggs"},{"title":"Bread"}]"#)

        #expect(result.isError == false)
        let tasks = try await repo.listActive()
        #expect(tasks.count == 3)
        #expect(Set(tasks.map(\.title)) == ["Milk", "Eggs", "Bread"])
    }

    @Test("returns one task artifact per created task")
    func artifactPerTask() async throws {
        let (tool, _) = try makeTool()
        let result = try await run(tool, #"[{"title":"A"},{"title":"B"}]"#)

        #expect(result.artifacts.count == 2)
        #expect(result.artifacts.allSatisfy { $0.type == "task" })
        #expect(result.artifacts.map(\.id) == ["task-1", "task-2"])
    }

    // MARK: - Per-item fields

    @Test("parses each priority name", arguments: [
        ("urgent", TaskPriority.urgent),
        ("high", TaskPriority.high),
        ("normal", TaskPriority.normal),
    ])
    func parsesPriority(name: String, expected: TaskPriority) async throws {
        let (tool, repo) = try makeTool()
        let result = try await run(tool, #"[{"title":"x","priority":"\#(name)"}]"#)

        #expect(result.isError == false)
        let task = try #require(try await repo.listActive().first)
        #expect(task.priority == expected)
    }

    @Test("parses a full ISO-8601 dueAt")
    func parsesFullISODueAt() async throws {
        let (tool, repo) = try makeTool()
        let result = try await run(tool, #"[{"title":"x","dueAt":"2026-06-10T09:00:00Z"}]"#)

        #expect(result.isError == false)
        let task = try #require(try await repo.listActive().first)
        let expected = ISO8601DateFormatter().date(from: "2026-06-10T09:00:00Z")
        #expect(task.dueAt == expected)
    }

    @Test("parses a date-only dueAt as UTC midnight")
    func parsesDateOnlyDueAt() async throws {
        let (tool, repo) = try makeTool()
        let result = try await run(tool, #"[{"title":"x","dueAt":"2026-06-10"}]"#)

        #expect(result.isError == false)
        let task = try #require(try await repo.listActive().first)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let expected = utc.date(from: DateComponents(year: 2026, month: 6, day: 10))
        #expect(task.dueAt == expected)
    }

    @Test("parses notes")
    func parsesNotes() async throws {
        let (tool, repo) = try makeTool()
        let result = try await run(tool, #"[{"title":"x","notes":"call the bank first"}]"#)

        #expect(result.isError == false)
        let task = try #require(try await repo.listActive().first)
        #expect(task.notes == "call the bank first")
    }

    // MARK: - Validation (all-or-nothing, soft errors)

    @Test("missing tasks param is a soft error")
    func missingParam() async throws {
        let (tool, repo) = try makeTool()
        let result = try await tool.execute(input: [:])

        #expect(result.isError == true)
        #expect(try await repo.listActive().isEmpty)
    }

    @Test("malformed JSON is a soft error and writes nothing")
    func malformedJSON() async throws {
        let (tool, repo) = try makeTool()
        let result = try await run(tool, "not json at all")

        #expect(result.isError == true)
        #expect(try await repo.listActive().isEmpty)
    }

    @Test("an empty array is a soft error")
    func emptyArray() async throws {
        let (tool, repo) = try makeTool()
        let result = try await run(tool, "[]")

        #expect(result.isError == true)
        #expect(try await repo.listActive().isEmpty)
    }

    @Test("a blank title anywhere rejects the whole batch")
    func blankTitleIsAtomic() async throws {
        let (tool, repo) = try makeTool()
        let result = try await run(tool, #"[{"title":"ok"},{"title":"   "}]"#)

        #expect(result.isError == true)
        #expect(try await repo.listActive().isEmpty)
    }

    @Test("an unknown priority rejects the whole batch")
    func invalidPriorityIsAtomic() async throws {
        let (tool, repo) = try makeTool()
        let result = try await run(tool, #"[{"title":"ok"},{"title":"x","priority":"medium"}]"#)

        #expect(result.isError == true)
        #expect(try await repo.listActive().isEmpty)
    }

    @Test("an unparseable dueAt rejects the whole batch")
    func invalidDueAtIsAtomic() async throws {
        let (tool, repo) = try makeTool()
        let result = try await run(tool, #"[{"title":"x","dueAt":"next tuesday"}]"#)

        #expect(result.isError == true)
        #expect(try await repo.listActive().isEmpty)
    }

    // MARK: - Registration

    @Test("registration advertises todo.create, enabled, with a required tasks param")
    func registration() async throws {
        let (_, repo) = try makeTool()
        let registration = TodoCreateTool.registration(repository: repo)

        #expect(registration.tool.id == "todo.create")
        #expect(registration.tool.appletId == "todo")
        #expect(registration.tool.category == .mutation)
        #expect(registration.isEnabled == true)
        let param = try #require(registration.tool.parameters.first)
        #expect(param.name == "tasks")
        #expect(param.isRequired == true)
    }
}
