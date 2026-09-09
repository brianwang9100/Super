#if DEBUG
import Core
import Foundation

public struct DebugTodoLLMProvider: LLMProvider {
    public let id: String
    public let displayName: String = "Debug (todo)"

    public static let modelID = "debug-todo"
    public static let modelDisplayName = "Debug todo"
    public static let maxContextTokens = 8_192

    /// Kept as a literal so Chat does not import Todo.
    static let toolName = "todo.create"

    public var supportedModels: [LLMModel] {
        [LLMModel(
            id: Self.modelID,
            displayName: Self.modelDisplayName,
            supportsThinking: false,
            supportsTools: true,
            maxContextTokens: Self.maxContextTokens
        )]
    }

    public init(id: String) {
        self.id = id
    }

    public func stream(
        messages: [LLMMessage],
        model: LLMModel,
        tools: [LLMTool],
        temperature: Double
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.messageStart(id: "debug-todo-\(UUID().uuidString)", model: model.id))

                // Loop termination — see DebugNoteLLMProvider for the rationale:
                // suppress only when *this* turn just ran the tool (the trailing
                // message is its `.tool` result), not whenever history contains
                // any tool result, so a fresh user turn after an earlier
                // debug-tool call still fires.
                guard messages.last?.role != .tool else {
                    continuation.yield(.contentBlockStart(index: 0, type: .text))
                    continuation.yield(.textDelta(index: 0, text: "Added those to your todos."))
                    continuation.yield(.contentBlockStop(index: 0))
                    continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
                    continuation.finish()
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: UInt64.random(in: 150...400) * 1_000_000)
                    continuation.yield(.contentBlockStart(index: 0, type: .toolUse))
                    continuation.yield(.toolUse(
                        index: 0,
                        id: "debug-tool-\(UUID().uuidString)",
                        name: Self.toolName,
                        input: Self.createInput(from: messages),
                        signature: nil
                    ))
                    continuation.yield(.contentBlockStop(index: 0))
                    continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
                } catch is CancellationError {
                    continuation.yield(.error(.cancelled))
                    continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
                } catch {
                    continuation.yield(.error(.requestFailed(error.localizedDescription)))
                    continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Canned payload

    /// One task object in the `todo.create` `tasks` payload. `Encodable`'s
    /// synthesized encoder omits the nil optionals, so a plain title encodes
    /// as `{"title":"…"}`.
    private struct TaskSpec: Encodable {
        let title: String
        var priority: String?
        var dueAt: String?
        var notes: String?
    }

    static func createInput(from messages: [LLMMessage]) -> JSONValue {
        .object(["tasks": .string(tasksJSON(from: messages))])
    }

    static func tasksJSON(from messages: [LLMMessage]) -> String {
        let specs = taskSpecs(from: messages)
        guard let data = try? JSONEncoder().encode(specs) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func taskSpecs(from messages: [LLMMessage]) -> [TaskSpec] {
        let titles = parseTitles(lastUserText(messages))
        guard !titles.isEmpty else { return cannedSpecs }
        return titles.map { TaskSpec(title: $0) }
    }

    /// Rich fallback used when the user turn carries no parseable titles, so a
    /// bare model selection still exercises priority / dueAt / notes parsing.
    private static let cannedSpecs: [TaskSpec] = [
        TaskSpec(title: "Buy groceries", priority: "high"),
        TaskSpec(title: "Pay rent", priority: "urgent", dueAt: "2026-12-01", notes: "Use the bank app"),
        TaskSpec(title: "Water the plants"),
    ]

    /// Pull task titles out of a free-text request: strip a leading command
    /// verb and a trailing "to my todos" tail, then split on commas and "and".
    static func parseTitles(_ rawText: String) -> [String] {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let lowered = text.lowercased()
        for prefix in ["add ", "create ", "remind me to ", "todos: ", "todo: "] {
            if lowered.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                break
            }
        }
        for suffix in [" to my todos", " to my todo list", " to my todo", " to todo"] {
            if text.lowercased().hasSuffix(suffix) {
                text = String(text.dropLast(suffix.count))
                break
            }
        }

        let normalized = text.replacingOccurrences(of: " and ", with: ",")
        let titles = normalized
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(titles.prefix(5))
    }

    private static func lastUserText(_ messages: [LLMMessage]) -> String {
        guard let last = messages.last(where: { $0.role == .user }) else { return "" }
        return last.content.compactMap { block in
            if case .text(let value) = block { return value }
            return nil
        }.joined(separator: " ")
    }
}
#endif
