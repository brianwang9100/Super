import Core
import Foundation
import os

private let chatSessionLog = Logger(subsystem: "com.brianwang.Super", category: "chat-session")

/// Runs one conversation's turn loop. Assistant output persists only on
/// `.messageComplete`; streaming deltas stay in memory. A replacement send
/// cancels and awaits the prior task before starting, preventing interleaved
/// database writes for the same conversation.
public actor ChatSession {
    public let conversationId: String

    private let messageRepository: any MessageRepository
    private let toolCallRepository: any ToolCallRepository
    private let checkpointRepository: any CompactionCheckpointRepository
    private let llmProviderRegistry: LLMProviderRegistry
    private let toolRegistry: ToolRegistry
    private let contextAssembler: ContextAssembler
    private let compactor: Compactor
    private let clock: any Clock
    private let idGenerator: any IDGenerator
    private let configuration: ChatSessionConfiguration

    /// Read per assembly so settings and tool edits affect the next turn.
    private let memoryRepository: (any MemoryRepository)?

    /// A missing mock fulfiller degrades the proposal to a declined search.
    private let webSearchFulfiller: (any WebSearchFulfilling)?

    /// Disables automatic compaction only; manual `/compact` remains available.
    private var autoCompactEnabled: Bool

    private var autoCompactThreshold: Double

    /// Manual compaction refuses below this ratio because the summary is not worthwhile.
    private let manualCompactMinThreshold: Double

    /// Requires approval before a billable native search when enabled.
    private var askBeforeSearching: Bool

    private var pendingConfirmations: [String: CheckedContinuation<Bool, Error>] = [:]

    /// Mock attribution is attached to the following grounded assistant message.
    private var pendingMockSources: [SourceCitation] = []
    private var pendingMockSuggestionsHTML: String?
    private var pendingMockQuery: String?

    private let chatBriefing: String

    /// Empty falls back to `chatBriefing` for compact-tier models.
    private let compactChatBriefing: String

    private let appletBriefings: [AppletBriefing]

    /// Compact-tier prompts keep only the active applet briefing when this is available.
    private let activeAppletID: (@Sendable () async -> String?)?

    /// Appended after authoritative briefing text so it cannot override system rules.
    private var currentUserPersonalization: String

    private var currentTask: Task<Void, Never>?

    private var liveTurn: LiveTurn?

    private struct LiveTurn {
        var accumulatedText: String = ""
        var accumulatedThinking: String = ""
        /// Preserves elapsed-thinking time across subscriber replacement.
        var thinkingStartedAt: Date?
        var subscribers: [UUID: AsyncStream<ChatEvent>.Continuation] = [:]
    }

    public struct LiveTurnSnapshot: Sendable {
        public let accumulatedText: String
        public let accumulatedThinking: String
        public let thinkingStartedAt: Date?

        public init(
            accumulatedText: String,
            accumulatedThinking: String,
            thinkingStartedAt: Date? = nil
        ) {
            self.accumulatedText = accumulatedText
            self.accumulatedThinking = accumulatedThinking
            self.thinkingStartedAt = thinkingStartedAt
        }
    }

    public init(
        conversationId: String,
        messageRepository: any MessageRepository,
        toolCallRepository: any ToolCallRepository,
        checkpointRepository: any CompactionCheckpointRepository,
        llmProviderRegistry: LLMProviderRegistry,
        toolRegistry: ToolRegistry,
        contextAssembler: ContextAssembler = ContextAssembler(),
        compactor: Compactor,
        clock: any Clock = SystemClock(),
        idGenerator: any IDGenerator = UUIDGenerator(),
        autoCompactEnabled: Bool = true,
        autoCompactThreshold: Double = ChatSettings.defaultAutoCompactThreshold,
        manualCompactMinThreshold: Double = ChatSettings.defaultManualCompactMinThreshold,
        askBeforeSearching: Bool = true,
        chatBriefing: String = "",
        compactChatBriefing: String = "",
        appletBriefings: [AppletBriefing] = [],
        activeAppletID: (@Sendable () async -> String?)? = nil,
        userPersonalization: String = "",
        memoryRepository: (any MemoryRepository)? = nil,
        webSearchFulfiller: (any WebSearchFulfilling)? = nil,
        configuration: ChatSessionConfiguration = .init()
    ) {
        self.conversationId = conversationId
        self.messageRepository = messageRepository
        self.toolCallRepository = toolCallRepository
        self.checkpointRepository = checkpointRepository
        self.llmProviderRegistry = llmProviderRegistry
        self.toolRegistry = toolRegistry
        self.contextAssembler = contextAssembler
        self.compactor = compactor
        self.clock = clock
        self.idGenerator = idGenerator
        self.autoCompactEnabled = autoCompactEnabled
        self.autoCompactThreshold = autoCompactThreshold
        self.manualCompactMinThreshold = manualCompactMinThreshold
        self.askBeforeSearching = askBeforeSearching
        self.chatBriefing = chatBriefing
        self.compactChatBriefing = compactChatBriefing
        self.appletBriefings = appletBriefings
        self.activeAppletID = activeAppletID
        self.currentUserPersonalization = userPersonalization
        self.memoryRepository = memoryRepository
        self.webSearchFulfiller = webSearchFulfiller
        self.configuration = configuration
    }

    public func setAutoCompactPolicy(enabled: Bool, threshold: Double) {
        self.autoCompactEnabled = enabled
        self.autoCompactThreshold = threshold
    }

    /// Existing parked proposals still require their original decision.
    public func setAskBeforeSearching(_ enabled: Bool) {
        self.askBeforeSearching = enabled
    }

    public func confirmToolCall(id: String) {
        if let continuation = pendingConfirmations.removeValue(forKey: id) {
            continuation.resume(returning: true)
        }
    }

    public func skipToolCall(id: String) {
        if let continuation = pendingConfirmations.removeValue(forKey: id) {
            continuation.resume(returning: false)
        }
    }

    /// Removing before resume makes confirm, skip, and cancel mutually exclusive.
    private func cancelPendingConfirmation(id: String) {
        if let continuation = pendingConfirmations.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        }
    }

    public func setUserPersonalization(_ value: String) {
        self.currentUserPersonalization = value
    }

    public var isStreaming: Bool {
        currentTask != nil
    }

    /// Fences any prior turn; slash commands do not create user message rows.
    public func send(
        text: String,
        model: LLMModel,
        references: [RecordReference] = [],
        temperature: Double = ChatSessionConfiguration.defaultTemperature
    ) async -> AsyncStream<ChatEvent> {
        guard !Task.isCancelled else { return cancelledStream() }
        if let command = SlashCommand(rawText: text) {
            return await dispatch(command: command, model: model)
        }

        if let prior = currentTask {
            prior.cancel()
            await prior.value
        }
        guard !Task.isCancelled else { return cancelledStream() }

        liveTurn = LiveTurn()
        let subscription = subscribe()
        let task = Task {
            await self.run(userText: text, references: references, model: model, temperature: temperature)
            self.finishLiveTurn()
        }
        currentTask = task
        // Ending one iterator must not cancel the actor-owned turn or other subscribers.
        return subscription.stream
    }

    /// Re-runs the persisted turn without inserting another user message.
    public func retry(
        model: LLMModel,
        temperature: Double = ChatSessionConfiguration.defaultTemperature
    ) async -> AsyncStream<ChatEvent> {
        guard !Task.isCancelled else { return cancelledStream() }
        if let prior = currentTask {
            prior.cancel()
            await prior.value
        }
        guard !Task.isCancelled else { return cancelledStream() }

        liveTurn = LiveTurn()
        let subscription = subscribe()
        let task = Task {
            await self.runRetry(model: model, temperature: temperature)
            self.finishLiveTurn()
        }
        currentTask = task
        return subscription.stream
    }

    /// Emits no compaction events when there is nothing to summarize.
    public func compact(model: LLMModel) async -> AsyncStream<ChatEvent> {
        if let prior = currentTask {
            prior.cancel()
            await prior.value
        }

        liveTurn = LiveTurn()
        let subscription = subscribe()
        let task = Task {
            await self.runCompaction(model: model)
            self.finishLiveTurn()
        }
        currentTask = task
        return subscription.stream
    }

    /// Late subscribers receive a snapshot plus future events; ending one
    /// subscription does not cancel the shared turn.
    public func subscribe() -> (snapshot: LiveTurnSnapshot?, stream: AsyncStream<ChatEvent>) {
        let (stream, continuation) = AsyncStream<ChatEvent>.makeStream()
        guard let live = liveTurn else {
            continuation.finish()
            return (nil, stream)
        }
        let id = UUID()
        liveTurn?.subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id: id) }
        }
        let snapshot = LiveTurnSnapshot(
            accumulatedText: live.accumulatedText,
            accumulatedThinking: live.accumulatedThinking,
            thinkingStartedAt: live.thinkingStartedAt
        )
        return (snapshot, stream)
    }

    private func broadcast(_ event: ChatEvent) {
        switch event {
        case .textDelta(let chunk):
            liveTurn?.accumulatedText += chunk
        case .thinkingDelta(let chunk):
            liveTurn?.accumulatedThinking += chunk
        case .assistantMessageSaved:
            liveTurn?.accumulatedText = ""
            liveTurn?.accumulatedThinking = ""
            liveTurn?.thinkingStartedAt = nil
        default:
            break
        }
        guard let subscribers = liveTurn?.subscribers else { return }
        for (_, continuation) in subscribers {
            continuation.yield(event)
        }
    }

    private func finishLiveTurn() {
        if let subscribers = liveTurn?.subscribers {
            for (_, continuation) in subscribers {
                continuation.finish()
            }
        }
        liveTurn = nil
    }

    private func removeSubscriber(id: UUID) {
        liveTurn?.subscribers.removeValue(forKey: id)
    }

    private func dispatch(command: SlashCommand, model: LLMModel) async -> AsyncStream<ChatEvent> {
        switch command {
        case .compact:
            return await compact(model: model)
        }
    }

    /// Already-persisted rows are not rolled back.
    public func cancel() {
        currentTask?.cancel()
    }

    /// Drains in-flight work for shutdown and deterministic tests.
    public func waitUntilFinished() async {
        await currentTask?.value
    }

    private func cancelledStream() -> AsyncStream<ChatEvent> {
        AsyncStream { continuation in
            continuation.yield(.error(.cancelled))
            continuation.finish()
        }
    }

    private func run(
        userText: String,
        references: [RecordReference],
        model: LLMModel,
        temperature: Double
    ) async {
        await runGuardedTurn {
            let userMessage = MessageRecord(
                id: self.idGenerator.nextID(),
                conversationId: self.conversationId,
                role: .user,
                content: userText,
                toolCallId: nil,
                createdAt: self.clock.now(),
                tokenCount: nil,
                attachmentsJSON: MessageRecord.encode(MessageAttachments(references: references))
            )
            try await self.messageRepository.save(userMessage)
            self.broadcast(.userMessageSaved(userMessage))

            let provider = try await self.llmProviderRegistry.requireActive()
            try await self.runTurnLoop(model: model, temperature: temperature, provider: provider)
        }
    }

    private func runRetry(model: LLMModel, temperature: Double) async {
        await runGuardedTurn {
            guard try await self.messageRepository.hasUserMessage(conversationId: self.conversationId) else {
                return
            }

            let provider = try await self.llmProviderRegistry.requireActive()
            try await self.runTurnLoop(model: model, temperature: temperature, provider: provider)
        }
    }

    /// Applies the shared error-to-event mapping and clears the completed task.
    private func runGuardedTurn(_ body: () async throws -> Void) async {
        defer { currentTask = nil }
        do {
            try await body()
        } catch is CancellationError {
            broadcast(.error(.cancelled))
        } catch let err as LLMError {
            broadcast(.error(err))
        } catch let err as CompactorError {
            switch err {
            case .emptySummary:
                broadcast(.error(.requestFailed("compaction returned empty summary")))
            case .llmError(let underlying):
                broadcast(.error(underlying))
            }
        } catch let err as LLMProviderRegistryError {
            switch err {
            case .noActiveProvider:
                broadcast(.error(.requestFailed("no active LLM provider configured")))
            case .unknownProvider(let id):
                broadcast(.error(.requestFailed("unknown LLM provider: \(id)")))
            }
        } catch {
            broadcast(.error(.requestFailed(error.localizedDescription)))
        }
    }

    /// Repeats provider turns until the model requests no more tools.
    private func runTurnLoop(
        model: LLMModel,
        temperature: Double,
        provider: LLMProvider
    ) async throws {
        let toolsEnabled = configuration.tools == .enabled
        let nativeSearch = toolsEnabled && NativeWebSearch.usesNativeSearch(model)
        let mockSearch = toolsEnabled && NativeWebSearch.usesMockSearch(model)
        // Approval and refusal apply only to this user message's tool loop.
        var searchApproved = false
        var searchDeclined = false
        // A failed mock answer must not leak its stashed sources into a later turn.
        pendingMockSources = []
        pendingMockSuggestionsHTML = nil
        pendingMockQuery = nil
        while true {
            try Task.checkCancellation()
            try await maybeAutoCompact(model: model)
            let history = try await assembleHistory(model: model)
            var tools = toolsEnabled ? CompactToolPolicy.filter(
                await toolRegistry.enabledTools(for: provider),
                tier: ModelContextTier(maxContextTokens: model.maxContextTokens)
            ) : []
            // Native search uses the sentinel after approval; mock search stays client-side.
            let nativeProposalActive = nativeSearch && askBeforeSearching && !searchApproved && !searchDeclined
            let mockProposalActive = mockSearch && !searchApproved && !searchDeclined
            if nativeSearch {
                if !askBeforeSearching || searchApproved {
                    tools.append(NativeWebSearch.sentinelTool)
                } else if !searchDeclined {
                    tools.append(NativeWebSearch.proposalTool)
                }
            } else if mockProposalActive {
                tools.append(NativeWebSearch.proposalTool)
            }
            let toolCalls = try await streamOneTurn(
                provider: provider,
                messages: history,
                model: model,
                tools: tools,
                temperature: temperature
            )
            if toolCalls.isEmpty { return }

            // The proposal is a gate and never executes through ToolRegistry.
            if nativeProposalActive || mockProposalActive,
               let proposal = toolCalls.first(where: { $0.toolName == NativeWebSearch.proposalToolName }) {
                let approved: Bool
                if askBeforeSearching {
                    do {
                        approved = try await awaitSearchDecision(for: proposal)
                    } catch {
                        // Shield the paired result write; strict providers reject orphaned tool uses.
                        await Task { [self] in
                            try? await resolveProposal(proposal, approved: false)
                        }.value
                        throw error
                    }
                } else {
                    approved = true
                }
                if approved { searchApproved = true } else { searchDeclined = true }
                // Context assembly repairs the narrow cancel-after-resume pairing gap.
                if mockSearch {
                    if approved {
                        try await fulfillMockSearch(proposal)
                    } else {
                        try await resolveProposal(proposal, approved: false)
                    }
                } else {
                    try await resolveProposal(proposal, approved: approved)
                }
                let others = toolCalls.filter { $0.id != proposal.id }
                if !others.isEmpty { try await executeToolCalls(others) }
                continue
            }

            try await executeToolCalls(toolCalls)
        }
    }

    /// Suspends for approval; actor serialization closes the store-versus-cancel race.
    private func awaitSearchDecision(for record: ToolCallRecord) async throws -> Bool {
        try await toolCallRepository.updateStatus(
            id: record.id,
            status: .awaitingConfirmation,
            result: nil,
            completedAt: nil
        )
        let parked = try await refreshed(record)
        broadcast(.toolCallAwaitingConfirmation(parked))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingConfirmations[record.id] = continuation
            }
        } onCancel: {
            Task { await self.cancelPendingConfirmation(id: record.id) }
        }
    }

    /// Persists the paired proposal result required by provider history validation.
    private func resolveProposal(_ record: ToolCallRecord, approved: Bool) async throws {
        let content = approved
            ? "Web search approved. Search now and ground your answer in the results, citing them."
            : "User declined web search. Answer from your own knowledge, and say so if you are unsure."
        let result = ToolResult(toolID: record.toolName, content: content, isError: false)
        try await toolCallRepository.updateStatus(
            id: record.id,
            status: approved ? .success : .cancelled,
            result: encodeJSON(result),
            completedAt: clock.now()
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
        broadcast(.toolCallCompleted(updated, result))
    }

    /// Grounds a mock model client-side; a missing fulfiller declines instead of fabricating sources.
    private func fulfillMockSearch(_ record: ToolCallRecord) async throws {
        guard let webSearchFulfiller else {
            try await resolveProposal(record, approved: false)
            return
        }
        let query = NativeWebSearch.proposedQuery(fromParametersJSON: record.parameters)
        let outcome = await webSearchFulfiller.search(query: query)

        // Attribute mock sources to the following grounded answer, like native citations.
        pendingMockSources = outcome.sources
        pendingMockSuggestionsHTML = outcome.searchSuggestionsHTML
        pendingMockQuery = query.isEmpty ? nil : query

        let result = ToolResult(toolID: record.toolName, content: outcome.findings, isError: false)
        try await toolCallRepository.updateStatus(
            id: record.id,
            status: .success,
            result: encodeJSON(result),
            completedAt: clock.now()
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
        broadcast(.toolCallCompleted(updated, result))
    }

    /// Builds provider history, replacing checkpointed rows with their summary.
    private func assembleHistory(model: LLMModel) async throws -> [LLMMessage] {
        try await assemble(model: model).messages
    }

    private func assemble(model: LLMModel) async throws -> ContextAssembly {
        async let messages = messageRepository.fetchAll(conversationId: conversationId)
        async let toolCalls = toolCallRepository.fetchByConversation(conversationId)
        async let checkpoint = checkpointRepository.liveCheckpoint(for: conversationId)
        async let memories = currentMemories()
        async let tools = toolRegistry.enabledTools()
        let tier = ModelContextTier(maxContextTokens: model.maxContextTokens)
        // Match the tier-filtered live request; transient search tools are a deliberate undercount.
        let budgetedTools = configuration.tools == .enabled
            ? CompactToolPolicy.filter(await tools, tier: tier) : []
        let briefings = await selectedBriefings(for: tier)
        return try await contextAssembler.assemble(
            messages: messages,
            toolCalls: toolCalls,
            checkpoint: checkpoint,
            model: model,
            chatBriefing: briefings.chat,
            appletBriefings: briefings.applets,
            userPersonalization: currentUserPersonalization,
            memories: memories,
            tools: budgetedTools,
            allowsWebSearch: configuration.tools == .enabled
        )
    }

    /// Re-tiers live when models or active applets change; unknown applets retain all briefings.
    private func selectedBriefings(
        for tier: ModelContextTier
    ) async -> (chat: String, applets: [AppletBriefing]) {
        guard tier == .compact else { return (chatBriefing, appletBriefings) }
        let chat = compactChatBriefing.isEmpty ? chatBriefing : compactChatBriefing
        var applets = appletBriefings.map { briefing in
            AppletBriefing(
                label: briefing.label,
                body: briefing.compactBody,
                appletID: briefing.appletID
            )
        }
        if let activeAppletID, let active = await activeAppletID() {
            let scoped = applets.filter { $0.appletID == active }
            if !scoped.isEmpty { applets = scoped }
        }
        return (chat, applets)
    }

    /// Includes memory IDs for later update/forget calls; read failures omit memories for one turn.
    private func currentMemories() async -> [MemoryEntry] {
        guard let memoryRepository else { return [] }
        guard let registration = await toolRegistry.registration(toolID: MemoryTool.toolID),
              registration.isEnabled else { return [] }
        do {
            return try await memoryRepository.all()
        } catch {
            chatSessionLog.error(
                "memoryRepository.all() failed; injecting empty memories block this turn: \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    /// Auto-compacts while preserving the configured recent-message tail.
    private func maybeAutoCompact(model: LLMModel) async throws {
        guard autoCompactEnabled else { return }
        let assembly = try await assemble(model: model)
        // Compact tiers gate history against capacity left after the fixed prompt floor.
        let tier = ModelContextTier(maxContextTokens: model.maxContextTokens)
        switch tier {
        case .compact:
            let threshold = min(autoCompactThreshold, ChatSettings.compactTierAutoCompactThreshold)
            guard assembly.isCompressibleOverThreshold(threshold) else { return }
        case .full:
            guard assembly.isOverThreshold(autoCompactThreshold) else { return }
        }
        try await runCompactionPass(model: model, keepMostRecent: Compactor.defaultKeepMostRecent)
    }

    /// Manual compaction rejects context below the minimum worthwhile ratio.
    private func runCompaction(model: LLMModel) async {
        await runGuardedTurn {
            let assembly = try await self.assemble(model: model)
            let tier = ModelContextTier(maxContextTokens: model.maxContextTokens)
            let gateRatio = tier == .compact ? assembly.compressibleRatio : assembly.ratio
            guard gateRatio >= self.manualCompactMinThreshold else {
                let pct = Int((self.manualCompactMinThreshold * 100).rounded())
                self.broadcast(.error(.requestFailed(
                    "Conversation is too short to compact yet — try again once context usage reaches \(pct)%."
                )))
                return
            }
            // Cover all current messages so the manual banner anchors at the end.
            try await self.runCompactionPass(model: model, keepMostRecent: 0)
        }
    }

    /// Emits compaction events only after confirming there is a summary window.
    private func runCompactionPass(model: LLMModel, keepMostRecent: Int) async throws {
        let messages = try await messageRepository.fetchAll(conversationId: conversationId)
        let toolCalls = try await toolCallRepository.fetchByConversation(conversationId)
        let prior = try await checkpointRepository.liveCheckpoint(for: conversationId)

        guard compactor.wouldCompact(
            messages: messages,
            priorCheckpoint: prior,
            keepMostRecent: keepMostRecent
        ) else {
            return
        }

        broadcast(.compactionStarted)
        let checkpoint = try await compactor.compact(
            conversationId: conversationId,
            messages: messages,
            toolCalls: toolCalls,
            priorCheckpoint: prior,
            model: model,
            keepMostRecent: keepMostRecent
        )
        // A nil result after a positive preflight means the shared slicing rules drifted.
        guard let checkpoint else {
            assertionFailure("Compactor.wouldCompact disagreed with Compactor.compact — slicing logic drifted")
            return
        }
        broadcast(.compactionCompleted(checkpoint))
    }

    /// Streams one provider round trip; outputless turns are not persisted.
    private func streamOneTurn(
        provider: any LLMProvider,
        messages: [LLMMessage],
        model: LLMModel,
        tools: [LLMTool],
        temperature: Double
    ) async throws -> [ToolCallRecord] {
        // The local conversation ID is stable cache affinity without message content.
        let stream = provider.stream(
            messages: messages,
            model: model,
            tools: tools,
            temperature: temperature,
            options: LLMRequestOptions(
                conversationCacheKey: conversationId,
                requiresCompleteResponse: configuration.requiresCompleteResponse
            )
        )

        liveTurn?.accumulatedText = ""
        liveTurn?.accumulatedThinking = ""
        liveTurn?.thinkingStartedAt = nil
        var thinkingEndedAt: Date?
        var pendingCalls: [(id: String, name: String, input: JSONValue, signature: String?)] = []
        var capturedUsage: TokenUsage?
        var streamError: LLMError?
        var accumulatedSources: [SourceCitation] = []
        var searchSuggestionsHTML: String?
        var searchStartedQuery: String?
        var capturedThinkingSignature: String?

        for try await event in stream {
            try Task.checkCancellation()
            if configuration.requiresCompleteResponse, capturedUsage != nil {
                switch event {
                case .error(let error): throw error
                case .textDelta, .thinkingDelta, .thinkingSignature, .toolUse,
                     .messageStart, .contentBlockStart:
                    throw LLMError.requestFailed("The response continued after it finished. Try again.")
                default: break
                }
            }
            switch event {
            case .messageStart, .contentBlockStart, .contentBlockStop:
                break
            case .textDelta(_, let text):
                broadcast(.textDelta(text))
            case .thinkingDelta(_, let text):
                let now = clock.now()
                if liveTurn?.thinkingStartedAt == nil {
                    liveTurn?.thinkingStartedAt = now
                }
                thinkingEndedAt = now
                broadcast(.thinkingDelta(text))
            case .thinkingSignature(_, let signature):
                // Anthropic requires verbatim signed-thinking replay in tool loops.
                capturedThinkingSignature = signature
            case .toolUse(_, let id, let name, let input, let signature):
                guard configuration.tools == .enabled else {
                    throw LLMError.requestFailed("The model returned a tool call instead of a response. Try again.")
                }
                pendingCalls.append((id, name, input, signature))
            case .searchStarted(let query):
                searchStartedQuery = query
            case .citations(let cites):
                for cite in cites {
                    let key = Self.citationDedupeKey(cite.url)
                    if !accumulatedSources.contains(where: { Self.citationDedupeKey($0.url) == key }) {
                        accumulatedSources.append(cite)
                    }
                }
            case .searchSuggestionsHTML(let html):
                searchSuggestionsHTML = html
            case .messageComplete(let usage):
                capturedUsage = usage
            case .error(let err):
                streamError = err
            }
        }

        if configuration.requiresCompleteResponse { try Task.checkCancellation() }
        if let err = streamError { throw err }
        if configuration.requiresCompleteResponse {
            guard capturedUsage != nil else {
                throw LLMError.requestFailed("The response was interrupted before it finished. Try again.")
            }
            if configuration.tools == .disabled,
               (liveTurn?.accumulatedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw LLMError.requestFailed("The model returned an empty response. Try again or choose another model.")
            }
        }

        // Cache telemetry records counts only, never message content.
        if let usage = capturedUsage {
            chatSessionLog.debug(
                "turn usage: input=\(usage.inputTokens, privacy: .public) output=\(usage.outputTokens, privacy: .public) cacheRead=\(usage.cacheReadInputTokens ?? 0, privacy: .public) cacheWrite=\(usage.cacheCreationInputTokens ?? 0, privacy: .public)"
            )
        }

        // Snapshot before the saved event clears buffers for the next tool-loop turn.
        let accumulatedText = liveTurn?.accumulatedText ?? ""
        let accumulatedThinking = liveTurn?.accumulatedThinking ?? ""
        let thinkingStartedAt = liveTurn?.thinkingStartedAt

        // Drain mock results onto the grounded answer and deduplicate native citations.
        if !pendingMockSources.isEmpty || pendingMockSuggestionsHTML != nil || pendingMockQuery != nil {
            for cite in pendingMockSources {
                let key = Self.citationDedupeKey(cite.url)
                if !accumulatedSources.contains(where: { Self.citationDedupeKey($0.url) == key }) {
                    accumulatedSources.append(cite)
                }
            }
            if searchSuggestionsHTML == nil { searchSuggestionsHTML = pendingMockSuggestionsHTML }
            if searchStartedQuery == nil { searchStartedQuery = pendingMockQuery }
            pendingMockSources = []
            pendingMockSuggestionsHTML = nil
            pendingMockQuery = nil
        }

        // Metadata-only and thinking-only turns are output; a truly empty turn is not a row.
        if accumulatedText.isEmpty,
           accumulatedThinking.isEmpty,
           pendingCalls.isEmpty,
           accumulatedSources.isEmpty,
           searchSuggestionsHTML == nil {
            return []
        }

        let thinkingDurationMs: Int? = {
            guard let start = thinkingStartedAt, let end = thinkingEndedAt else { return nil }
            return max(0, Int(end.timeIntervalSince(start) * 1000))
        }()
        let didSearch = !accumulatedSources.isEmpty || searchStartedQuery != nil
        let searchSystem: String? = {
            guard didSearch else { return nil }
            if NativeWebSearch.usesMockSearch(model) { return "Debug (mock)" }
            if NativeWebSearch.usesNativeSearch(model) { return "Native search" }
            return provider.displayName
        }()
        let attachments = MessageAttachments(
            sources: accumulatedSources,
            searchSuggestionsHTML: searchSuggestionsHTML,
            searchQuery: didSearch ? searchStartedQuery : nil,
            searchSystem: searchSystem
        )
        let assistantMessage = MessageRecord(
            id: idGenerator.nextID(),
            conversationId: conversationId,
            role: .assistant,
            content: accumulatedText,
            thinkingContent: accumulatedThinking.isEmpty ? nil : accumulatedThinking,
            thinkingDurationMs: thinkingDurationMs,
            thinkingSignature: accumulatedThinking.isEmpty ? nil : capturedThinkingSignature,
            thinkingModelId: accumulatedThinking.isEmpty ? nil : model.id,
            toolCallId: nil,
            createdAt: clock.now(),
            tokenCount: capturedUsage?.outputTokens,
            attachmentsJSON: MessageRecord.encode(attachments)
        )
        try await messageRepository.save(assistantMessage)
        broadcast(.assistantMessageSaved(assistantMessage))

        var savedCalls: [ToolCallRecord] = []
        // Assembly repairs cancellation between these writes; launch recovery settles status.
        for call in pendingCalls {
            let parametersJSON = encodeJSON(call.input)
            // Mint marked IDs for missing/provider-fallback IDs to avoid upsert collisions.
            let persistedID = call.id.isEmpty || call.id == call.name
                ? ToolCallRecord.locallyMintedID(idGenerator.nextID())
                : call.id
            let record = ToolCallRecord(
                id: persistedID,
                messageId: assistantMessage.id,
                conversationId: conversationId,
                toolName: call.name,
                parameters: parametersJSON,
                result: nil,
                status: .pending,
                createdAt: clock.now(),
                completedAt: nil,
                signature: call.signature
            )
            try await toolCallRepository.save(record)
            broadcast(.toolCallStarted(record))
            savedCalls.append(record)
        }

        return savedCalls
    }

    private func executeToolCalls(_ records: [ToolCallRecord]) async throws {
        for (index, record) in records.enumerated() {
            do {
                try Task.checkCancellation()
                try await executeSingleToolCall(record)
            } catch is CancellationError {
                // Shield cancelled results for the batch tail; strict providers reject orphaned uses.
                await Task { [self] in
                    await cancelUnresolvedToolCalls(Array(records[index...]))
                }.value
                throw CancellationError()
            }
        }
    }

    /// Best-effort pairing for cancelled batch tails; assembly backstops failed teardown writes.
    private func cancelUnresolvedToolCalls(_ records: [ToolCallRecord]) async {
        for record in records {
            let result = ToolResult(
                toolID: record.toolName,
                content: "Tool execution was cancelled by the user before completing. Do not retry automatically.",
                isError: false
            )
            try? await toolCallRepository.updateStatus(
                id: record.id,
                status: .cancelled,
                result: encodeJSON(result),
                completedAt: clock.now()
            )
            let toolResultMessage = MessageRecord(
                id: idGenerator.nextID(),
                conversationId: conversationId,
                role: .tool,
                content: result.content,
                toolCallId: record.id,
                createdAt: clock.now(),
                tokenCount: nil
            )
            try? await messageRepository.save(toolResultMessage)
            if let updated = try? await refreshed(record) {
                broadcast(.toolCallCompleted(updated, result))
            }
        }
    }

    /// Tool failures persist as results; cancellation propagates so the batch tail can be paired.
    private func executeSingleToolCall(_ record: ToolCallRecord) async throws {
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
            // Do not persist success after cancellation began.
            try Task.checkCancellation()
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
            broadcast(.toolCallCompleted(updated, result))

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
            broadcast(.toolCallFailed(updated, message))
        }
    }

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

    /// Dedup key for a citation URL. Scheme and host are case-insensitive per
    /// RFC 3986, so `HTTPS://Example.com/A` and `https://example.com/A` are the
    /// same source; the path stays case-sensitive. Falls back to the raw string
    /// for URLs without a host.
    private static func citationDedupeKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.url?.absoluteString ?? url.absoluteString
    }
}

private func encodeJSON(_ value: JSONValue) -> String {
    // Invalid JSON values are programmer errors; silently replacing tool input would corrupt history.
    // swiftlint:disable:next force_try
    let data = try! JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
}

/// Internal so interruption recovery writes the identical result shape.
func encodeJSON(_ value: ToolResult) -> String {
    // This string/bool-only payload must encode; failure signals a programmer error.
    // swiftlint:disable:next force_try
    let data = try! JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
}
