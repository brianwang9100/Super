import Core
import Foundation

/// Owns the turn loop for a single conversation. One `ChatSession` per
/// conversation; multiple sessions run concurrently under a
/// `ChatSessionStore` without sharing state.
///
/// `send(text:model:temperature:)` returns an `AsyncStream<ChatEvent>` and
/// spawns the streaming task on the session. The task lives independent of
/// the returned stream's iteration — switching away from a streaming chat
/// in the UI does not cancel the work; switching back can re-attach via a
/// fresh stream by replaying the GRDB-backed messages.
///
/// ## Turn loop
///
/// 1. Save the user `MessageRecord`.
/// 2. Loop:
///    1. Fetch every `MessageRecord` + `ToolCallRecord` for this
///       conversation and project them into `[LLMMessage]`.
///    2. Stream from the active `LLMProvider` with the currently-enabled
///       tools. Buffer text/thinking deltas in memory.
///    3. On `.messageComplete`, persist the assistant `MessageRecord` (per
///       ADR-BB-003 we never write per-delta) and a `ToolCallRecord`
///       (`status = .pending`) per requested tool call. An empty turn
///       (no text, no tool calls) is not persisted.
///    4. If no tool calls were requested, finish.
///    5. Otherwise execute each tool via `ToolRegistry`, write a tool
///       result `MessageRecord` (role `.tool`), update the
///       `ToolCallRecord` status, and loop back.
///
/// ## Cancellation
///
/// `cancel()` cancels the in-flight `Task`. Already-persisted rows stay;
/// nothing rolls back. The stream emits `.error(.cancelled)` and finishes.
/// A second `send(...)` while a turn is in flight cancels the prior task
/// **and awaits its wind-down** before starting the new one — this fence
/// prevents two turns from interleaving GRDB writes for the same
/// conversation.
public actor ChatSession {
    public let conversationId: String

    private let messageRepository: any MessageRepository
    private let toolCallRepository: any ToolCallRepository
    private let llmProviderRegistry: LLMProviderRegistry
    private let toolRegistry: ToolRegistry
    private let clock: any Clock
    private let idGenerator: any IDGenerator

    /// The in-flight turn's task, or `nil` between turns. Cleared from
    /// inside `run`'s `defer` so `isStreaming` flips back to `false` as
    /// soon as the work finishes (and so a subsequent `send(...)` doesn't
    /// pointlessly await an already-completed task).
    private var currentTask: Task<Void, Never>?

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - clock: Injected so tests can substitute a `FixedClock` and
    ///     assert deterministic `createdAt` timestamps on persisted rows.
    ///     The repository ordering uses `(createdAt, rowid)` so a true
    ///     fixed clock still yields deterministic history order.
    ///   - idGenerator: Injected so tests can substitute a
    ///     `DeterministicIDGenerator` and assert exact `MessageRecord` ids.
    public init(
        conversationId: String,
        messageRepository: any MessageRepository,
        toolCallRepository: any ToolCallRepository,
        llmProviderRegistry: LLMProviderRegistry,
        toolRegistry: ToolRegistry,
        clock: any Clock = SystemClock(),
        idGenerator: any IDGenerator = UUIDGenerator()
    ) {
        self.conversationId = conversationId
        self.messageRepository = messageRepository
        self.toolCallRepository = toolCallRepository
        self.llmProviderRegistry = llmProviderRegistry
        self.toolRegistry = toolRegistry
        self.clock = clock
        self.idGenerator = idGenerator
    }

    /// `true` while a turn is mid-flight. Sidebar drives the per-row
    /// running spinner from the store-aggregated value of this property.
    /// Flips back to `false` the moment `run` returns (success, error, or
    /// cancellation).
    public var isStreaming: Bool {
        currentTask != nil
    }

    /// Submit a user message and stream events for the resulting turn(s).
    /// If a prior turn is still in flight, this cancels it and awaits its
    /// wind-down before the new turn begins, so the two turns never
    /// interleave their database writes. The UI typically blocks the
    /// composer during streaming, so the prior-turn fence is a defensive
    /// guard rather than the common path.
    public func send(
        text: String,
        model: LLMModel,
        temperature: Double = 1.0
    ) async -> AsyncStream<ChatEvent> {
        if let prior = currentTask {
            prior.cancel()
            await prior.value
        }

        let (stream, continuation) = AsyncStream<ChatEvent>.makeStream()
        let task = Task {
            await self.run(
                userText: text,
                model: model,
                temperature: temperature,
                continuation: continuation
            )
            continuation.finish()
        }
        currentTask = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Cancel the in-flight turn, if any. Already-persisted rows stay;
    /// nothing rolls back. Returns immediately — call `waitUntilFinished()`
    /// if you need to synchronize on the task's wind-down.
    public func cancel() {
        currentTask?.cancel()
    }

    /// Await the completion of the in-flight turn task. Useful in tests
    /// that need to ensure all GRDB writes have settled before asserting,
    /// and used by `ChatSessionStore.shutdown()` to drain in-flight work.
    public func waitUntilFinished() async {
        await currentTask?.value
    }

    private func run(
        userText: String,
        model: LLMModel,
        temperature: Double,
        continuation: AsyncStream<ChatEvent>.Continuation
    ) async {
        defer { currentTask = nil }

        do {
            let userMessage = MessageRecord(
                id: idGenerator.nextID(),
                conversationId: conversationId,
                role: .user,
                content: userText,
                toolCallId: nil,
                createdAt: clock.now(),
                tokenCount: nil
            )
            try await messageRepository.save(userMessage)
            continuation.yield(.userMessageSaved(userMessage))

            let provider = try await llmProviderRegistry.requireActive()

            while true {
                try Task.checkCancellation()
                let history = try await assembleHistory()
                let enabledTools = await toolRegistry.enabledTools(for: provider)
                let toolCalls = try await streamOneTurn(
                    provider: provider,
                    messages: history,
                    model: model,
                    tools: enabledTools,
                    temperature: temperature,
                    continuation: continuation
                )
                if toolCalls.isEmpty { return }
                try await executeToolCalls(toolCalls, continuation: continuation)
            }
        } catch is CancellationError {
            continuation.yield(.error(.cancelled))
        } catch let err as LLMError {
            continuation.yield(.error(err))
        } catch let err as LLMProviderRegistryError {
            switch err {
            case .noActiveProvider:
                continuation.yield(.error(.requestFailed("no active LLM provider configured")))
            case .unknownProvider(let id):
                continuation.yield(.error(.requestFailed("unknown LLM provider: \(id)")))
            }
        } catch {
            continuation.yield(.error(.requestFailed(error.localizedDescription)))
        }
    }

    /// Project the on-disk records back into the LLM-facing message shape.
    /// Assistant rows fold their tool-call rows in as `.toolUse` blocks;
    /// tool result rows look up their originating call to learn whether
    /// they should carry `isError: true`. Tool calls are read in
    /// `(createdAt, rowid)` order from the repository, so the per-message
    /// grouping preserves issue order without needing a re-sort here.
    private func assembleHistory() async throws -> [LLMMessage] {
        let priorMessages = try await messageRepository.fetchAll(conversationId: conversationId)
        let priorToolCalls = try await toolCallRepository.fetchByConversation(conversationId)

        var toolCallsByMessageID: [String: [ToolCallRecord]] = [:]
        var toolCallsByID: [String: ToolCallRecord] = [:]
        for record in priorToolCalls {
            toolCallsByMessageID[record.messageId, default: []].append(record)
            toolCallsByID[record.id] = record
        }

        var llmMessages: [LLMMessage] = []
        for record in priorMessages {
            switch record.role {
            case .system:
                llmMessages.append(LLMMessage(role: .system, text: record.content))
            case .user:
                llmMessages.append(LLMMessage(role: .user, text: record.content))
            case .assistant:
                var blocks: [LLMContent] = []
                if !record.content.isEmpty {
                    blocks.append(.text(record.content))
                }
                for call in toolCallsByMessageID[record.id] ?? [] {
                    let input = try call.decodedParameters()
                    blocks.append(.toolUse(id: call.id, name: call.toolName, input: input))
                }
                if !blocks.isEmpty {
                    llmMessages.append(LLMMessage(role: .assistant, content: blocks))
                }
            case .tool:
                guard let toolCallID = record.toolCallId else { continue }
                let isError = toolCallsByID[toolCallID]?.status == .failed
                llmMessages.append(LLMMessage(role: .tool, content: [
                    .toolResult(toolUseID: toolCallID, content: record.content, isError: isError),
                ]))
            }
        }
        return llmMessages
    }

    /// Drive one round trip through the provider. Returns the tool calls
    /// requested in this turn (if any) so the caller can decide whether to
    /// loop or stop. An empty turn (the provider yields no text and no
    /// tool calls before `.messageComplete`) is not persisted: no
    /// `MessageRecord` is written and no `.assistantMessageSaved` event
    /// fires, so the on-disk and LLM-facing histories stay in sync.
    private func streamOneTurn(
        provider: any LLMProvider,
        messages: [LLMMessage],
        model: LLMModel,
        tools: [LLMTool],
        temperature: Double,
        continuation: AsyncStream<ChatEvent>.Continuation
    ) async throws -> [ToolCallRecord] {
        let stream = provider.stream(
            messages: messages,
            model: model,
            tools: tools,
            temperature: temperature
        )

        var accumulatedText = ""
        var pendingCalls: [(id: String, name: String, input: JSONValue)] = []
        var capturedUsage: TokenUsage?
        var streamError: LLMError?

        for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .messageStart, .contentBlockStart, .contentBlockStop:
                break
            case .textDelta(_, let text):
                accumulatedText += text
                continuation.yield(.textDelta(text))
            case .thinkingDelta(_, let text):
                continuation.yield(.thinkingDelta(text))
            case .toolUse(_, let id, let name, let input):
                pendingCalls.append((id, name, input))
            case .messageComplete(let usage):
                capturedUsage = usage
            case .error(let err):
                streamError = err
            }
        }

        if let err = streamError { throw err }

        // Skip empty turns — the LLM yielded `.messageComplete` without
        // any text or tool calls. Persisting an empty assistant row would
        // diverge the on-disk view from `assembleHistory`'s output (which
        // drops empty rows when projecting back).
        if accumulatedText.isEmpty && pendingCalls.isEmpty {
            return []
        }

        let assistantMessage = MessageRecord(
            id: idGenerator.nextID(),
            conversationId: conversationId,
            role: .assistant,
            content: accumulatedText,
            toolCallId: nil,
            createdAt: clock.now(),
            tokenCount: capturedUsage?.outputTokens
        )
        try await messageRepository.save(assistantMessage)
        continuation.yield(.assistantMessageSaved(assistantMessage))

        var savedCalls: [ToolCallRecord] = []
        for call in pendingCalls {
            let parametersJSON = encodeJSON(call.input)
            let record = ToolCallRecord(
                id: call.id,
                messageId: assistantMessage.id,
                conversationId: conversationId,
                toolName: call.name,
                parameters: parametersJSON,
                result: nil,
                status: .pending,
                createdAt: clock.now(),
                completedAt: nil
            )
            try await toolCallRepository.save(record)
            continuation.yield(.toolCallStarted(record))
            savedCalls.append(record)
        }

        return savedCalls
    }

    private func executeToolCalls(
        _ records: [ToolCallRecord],
        continuation: AsyncStream<ChatEvent>.Continuation
    ) async throws {
        for record in records {
            try Task.checkCancellation()

            try await toolCallRepository.updateStatus(
                id: record.id,
                status: .executing,
                result: nil,
                completedAt: nil
            )

            let outcome: ToolOutcome
            do {
                let inputDict = try toolInputDict(from: record)
                let result = try await toolRegistry.execute(
                    toolID: record.toolName,
                    input: inputDict
                )
                outcome = .success(result)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let failure = ToolResult(
                    toolID: record.toolName,
                    content: "Error: \(error.localizedDescription)",
                    isError: true
                )
                outcome = .failure(failure, message: error.localizedDescription)
            }

            let now = clock.now()
            switch outcome {
            case .success(let result):
                try await toolCallRepository.updateStatus(
                    id: record.id,
                    status: .success,
                    result: encodeJSON(result),
                    completedAt: now
                )
                let updated = try await refreshed(record)
                let toolResultMessage = MessageRecord(
                    id: idGenerator.nextID(),
                    conversationId: conversationId,
                    role: .tool,
                    content: result.content,
                    toolCallId: record.id,
                    createdAt: clock.now(),
                    tokenCount: nil
                )
                try await messageRepository.save(toolResultMessage)
                continuation.yield(.toolCallCompleted(updated, result))

            case .failure(let failureResult, let message):
                try await toolCallRepository.updateStatus(
                    id: record.id,
                    status: .failed,
                    result: encodeJSON(failureResult),
                    completedAt: now
                )
                let updated = try await refreshed(record)
                let errorMessageRow = MessageRecord(
                    id: idGenerator.nextID(),
                    conversationId: conversationId,
                    role: .tool,
                    content: failureResult.content,
                    toolCallId: record.id,
                    createdAt: clock.now(),
                    tokenCount: nil
                )
                try await messageRepository.save(errorMessageRow)
                continuation.yield(.toolCallFailed(updated, message))
            }
        }
    }

    /// Re-fetch a `ToolCallRecord` after a `updateStatus(...)` call so the
    /// event we yield carries the post-update row rather than a hand-
    /// mirrored snapshot. Falls back to the input record only if the row
    /// vanished mid-flight (which can't happen given the just-completed
    /// write — but the fallback keeps the call total).
    private func refreshed(_ record: ToolCallRecord) async throws -> ToolCallRecord {
        try await toolCallRepository.fetch(id: record.id) ?? record
    }

    private func toolInputDict(from record: ToolCallRecord) throws -> [String: JSONValue] {
        let value = try record.decodedParameters()
        if case .object(let dict) = value { return dict }
        return [:]
    }

    private enum ToolOutcome {
        case success(ToolResult)
        case failure(ToolResult, message: String)
    }
}

/// Encode a `JSONValue` to its JSON (JavaScript Object Notation) string.
/// Total over `JSONValue` because every case has a defined encoding.
private func encodeJSON(_ value: JSONValue) -> String {
    // swiftlint:disable:next force_try
    let data = try! JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
}

/// Encode a `ToolResult` to its JSON string. `ToolResult` is fully
/// `Codable` over `String`, `Bool`, and `[Artifact]`, so encoding is
/// total — a `try!` here is a programmer-error catcher rather than a
/// silent fallback.
private func encodeJSON(_ value: ToolResult) -> String {
    // swiftlint:disable:next force_try
    let data = try! JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
}
