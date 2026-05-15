import Testing
@testable import Todo

/// Round-trips and ordering for the `TaskState` and `TaskPriority` enums.
@Suite("TaskState / TaskPriority")
struct TaskStateTests {
    @Test func taskStateRawValueRoundTrips() {
        for state in TaskState.allCases {
            #expect(TaskState(rawValue: state.rawValue) == state)
        }
    }

    @Test func taskPriorityRawValueRoundTrips() {
        for priority in TaskPriority.allCases {
            #expect(TaskPriority(rawValue: priority.rawValue) == priority)
        }
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
