import Core
import Foundation

final class FakeToolExecutor: ToolExecutor, Sendable {
    let toolID: String
    private let state: FakeToolExecutorState

    init(toolID: String) {
        self.toolID = toolID
        self.state = FakeToolExecutorState()
    }

    func setResult(_ result: ToolResult) async {
        await state.setResult(result)
    }

    func setError(_ error: FakeToolError) async {
        await state.setError(error)
    }

    func capturedInputs() async -> [[String: JSONValue]] {
        await state.capturedInputs()
    }

    func executionCount() async -> Int {
        await state.executionCount()
    }

    func execute(input: [String: JSONValue]) async throws -> ToolResult {
        try await state.execute(input: input)
    }
}

/// LocalizedError exposes the scripted payload through the orchestrator error path.
enum FakeToolError: Error, Equatable, Sendable, LocalizedError {
    case scripted(String)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .scripted(let message): return message
        case .notConfigured: return "FakeToolExecutor: result/error not configured"
        }
    }
}

private actor FakeToolExecutorState {
    private var result: ToolResult?
    private var error: FakeToolError?
    private var inputs: [[String: JSONValue]] = []

    func setResult(_ value: ToolResult) {
        result = value
        error = nil
    }

    func setError(_ value: FakeToolError) {
        error = value
        result = nil
    }

    func capturedInputs() -> [[String: JSONValue]] { inputs }
    func executionCount() -> Int { inputs.count }

    func execute(input: [String: JSONValue]) throws -> ToolResult {
        inputs.append(input)
        if let error { throw error }
        if let result { return result }
        throw FakeToolError.notConfigured
    }
}
