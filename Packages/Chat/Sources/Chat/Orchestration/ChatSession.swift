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
///       (`status = .pending`) per requested tool call.
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
/// before starting a new one — the UI typically blocks the composer during
/// streaming, so this is a defensive guard rather than the common path.
public actor ChatSession {
    public let conversationId: String

    private let messageRepository: any MessageRepository
    private let toolCallRepository: any ToolCallRepository
    private let llmProviderRegistry: LLMProviderRegistry
    private let toolRegistry: ToolRegistry
    private let clock: any Clock
    private let idGenerator: any IDGenerator

    private var currentTask: Task<Void, Never>?

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - clock: Injected so tests can substitute a `FixedClock` and
    ///     assert deterministic `createdAt` timestamps on persisted rows.
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

    /// `true` while a turn is mid-flight. The store consults this to drive
    /// the sidebar's per-conversation running spinner.
    public var isStreaming: Bool {
        guard let task = currentTask else { return false }
        return !task.isCancelled
    }

    /// Submit a user message and stream events for the resulting turn(s).
    /// Cancels any prior in-flight turn on this session before starting.
    public func send(
        text: String,
        model: LLMModel,
        temperature: Double = 1.0
    ) -> AsyncStream<ChatEvent> {
        currentTask?.cancel()

        let (stream, continuation) = AsyncStream<ChatEvent>.makeStream()
        let task = Task { [weak self] in
            guard let self else {
                continuation.finish()
                return
            }
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
    /// that need to ensure all GRDB writes have settled before asserting.
    public func waitUntilFinished() async {
        await currentTask?.value
    }

    private func run(
        userText: String,
        model: LLMModel,
        temperature: Double,
        continuation: AsyncStream<ChatEvent>.Continuation
    ) async {
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

            while !Task.isCancelled {
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

            continuation.yield(.error(.cancelled))
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
    /// they should carry `isError: true`.
    private func assembleHistory() async throws -> [LLMMessage] {
        let priorMessages = try await messageRepository.fetchAll(conversationId: conversationId)
        let priorToolCalls = try await toolCallRepository.fetchByConversation(conversationId)

        var toolCallsByMessageID: [String: [ToolCallRecord]] = [:]
        var toolCallsByID: [String: ToolCallRecord] = [:]
        for record in priorToolCalls {
            toolCallsByMessageID[record.messageId, default: []].append(record)
            toolCallsByID[record.id] = record
        }
        for messageID in toolCallsByMessageID.keys {
            toolCallsByMessageID[messageID]?.sort(by: { $0.createdAt < $1.createdAt })
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
                    let input = (try? call.decodedParameters()) ?? .object([:])
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
    /// loop or stop.
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

        do {
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
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Per the `LLMProvider` contract the stream never throws —
            // failures arrive as `.error` events. If something throws
            // anyway, treat it as transport.
            streamError = .requestFailed(error.localizedDescription)
        }

        if let err = streamError { throw err }

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
            let parametersJSON = (try? ToolCallRecord.encode(call.input)) ?? "{}"
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
        for var record in records {
            try Task.checkCancellation()

            try await toolCallRepository.updateStatus(
                id: record.id,
                status: .executing,
                result: nil,
                completedAt: nil
            )
            record.status = .executing

            do {
                let inputDict = (try toolInputDict(from: record))
                let result: ToolResult
                do {
                    result = try await toolRegistry.execute(
                        toolID: record.toolName,
                        input: inputDict
                    )
                } catch is CancellationError {
                    throw CancellationError()
                }
                let now = clock.now()
                let resultJSON = encodeToolResult(result)
                try await toolCallRepository.updateStatus(
                    id: record.id,
                    status: .success,
                    result: resultJSON,
                    completedAt: now
                )
                record.status = .success
                record.result = resultJSON
                record.completedAt = now

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
                continuation.yield(.toolCallCompleted(record, result))
            } catch {
                let now = clock.now()
                let errorMessage = "Error: \(error.localizedDescription)"
                try? await toolCallRepository.updateStatus(
                    id: record.id,
                    status: .failed,
                    result: errorMessage,
                    completedAt: now
                )
                record.status = .failed
                record.result = errorMessage
                record.completedAt = now

                let errorMessageRow = MessageRecord(
                    id: idGenerator.nextID(),
                    conversationId: conversationId,
                    role: .tool,
                    content: errorMessage,
                    toolCallId: record.id,
                    createdAt: clock.now(),
                    tokenCount: nil
                )
                try? await messageRepository.save(errorMessageRow)
                continuation.yield(.toolCallFailed(record, error.localizedDescription))
            }
        }
    }

    private func toolInputDict(from record: ToolCallRecord) throws -> [String: JSONValue] {
        let value = try record.decodedParameters()
        if case .object(let dict) = value { return dict }
        return [:]
    }

    private func encodeToolResult(_ result: ToolResult) -> String {
        do {
            let data = try JSONEncoder().encode(result)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{}"
        }
    }
}
