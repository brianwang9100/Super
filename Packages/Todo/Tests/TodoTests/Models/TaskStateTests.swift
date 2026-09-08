import Testing
@testable import Todo

/// Persisted identifiers and ordering for the `TaskState` and `TaskPriority` enums.
@Suite("TaskState / TaskPriority")
struct TaskStateTests {
    @Test func taskStateRawValuesMatchPersistedFormat() {
        #expect(TaskState.open.rawValue == "open")
        #expect(TaskState.done.rawValue == "done")
        #expect(TaskState.cancelled.rawValue == "cancelled")
    }

    @Test func taskPriorityRawValuesMatchPersistedFormat() {
        #expect(TaskPriority.urgent.rawValue == 1)
        #expect(TaskPriority.high.rawValue == 2)
        #expect(TaskPriority.normal.rawValue == 3)
    }

    @Test func taskPriorityComparesByRawValue() {
        #expect(TaskPriority.urgent < TaskPriority.high)
        #expect(TaskPriority.high < TaskPriority.normal)
    }

    @Test func taskStateTerminalityMatchesDesign() {
        #expect(!TaskState.open.isTerminal)
        #expect(TaskState.done.isTerminal)
        #expect(TaskState.cancelled.isTerminal)
    }
}
