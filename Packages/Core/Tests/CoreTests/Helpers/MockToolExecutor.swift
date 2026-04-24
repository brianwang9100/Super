import Foundation
import os
@testable import Core

/// `ToolExecutor` test double. Records every invocation and either replays
/// a fixed `ToolResult` or runs a caller-supplied closure to produce one.
final class MockToolExecutor: ToolExecutor {
    let toolID: String
    private let invocations: OSAllocatedUnfairLock<[[String: JSONValue]]>
    private let nextResult: @Sendable (Int, [String: JSONValue]) -> ToolResult

    init(toolID: String, result: @escaping @Sendable (Int, [String: JSONValue]) -> ToolResult) {
        self.toolID = toolID
        self.invocations = OSAllocatedUnfairLock(initialState: [])
        self.nextResult = result
    }

    convenience init(toolID: String, result: ToolResult) {
        self.init(toolID: toolID) { _, _ in result }
    }

    func execute(input: [String: JSONValue]) async throws -> ToolResult {
        let count = invocations.withLock { state -> Int in
            state.append(input)
            return state.count
        }
        return nextResult(count, input)
    }

    var invocationCount: Int {
        invocations.withLock { $0.count }
    }

    var lastInput: [String: JSONValue]? {
        invocations.withLock { $0.last }
    }
}

/// In-memory `ToolEnablementStore` for tests. The Chat applet ships the
/// real GRDB-backed conformer.
final class InMemoryToolEnablementStore: ToolEnablementStore {
    private let state: OSAllocatedUnfairLock<[String: Bool]>

    init(initial: [String: Bool] = [:]) {
        self.state = OSAllocatedUnfairLock(initialState: initial)
    }

    func isEnabled(toolID: String) async throws -> Bool? {
        state.withLock { $0[toolID] }
    }

    func setEnabled(toolID: String, enabled: Bool) async throws {
        state.withLock { $0[toolID] = enabled }
    }

    func allEnabled() async throws -> [String: Bool] {
        state.withLock { $0 }
    }

    var snapshot: [String: Bool] {
        state.withLock { $0 }
    }
}
