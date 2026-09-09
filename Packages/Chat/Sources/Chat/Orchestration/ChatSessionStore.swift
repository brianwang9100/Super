import Core
import Foundation

/// Own sessions beyond view-model lifetimes so switching chats does not cancel streaming.
/// Cancelling one session leaves sibling turns running.
public actor ChatSessionStore {
    private let messageRepository: any MessageRepository
    private let toolCallRepository: any ToolCallRepository
    private let checkpointRepository: any CompactionCheckpointRepository
    private let llmProviderRegistry: LLMProviderRegistry
    private let toolRegistry: ToolRegistry
    private let contextAssembler: ContextAssembler
    private let compactor: Compactor
    private let clock: any Clock
    private let idGenerator: any IDGenerator
    private var autoCompactEnabled: Bool
    private var autoCompactThreshold: Double
    private let manualCompactMinThreshold: Double
    private var askBeforeSearching: Bool
    private let chatBriefing: String
    private let compactChatBriefing: String
    private let appletBriefings: [AppletBriefing]
    private let activeAppletID: (@Sendable () async -> String?)?
    private var currentUserPersonalization: String
    private let memoryRepository: (any MemoryRepository)?
    private let webSearchFulfiller: (any WebSearchFulfilling)?

    private var sessions: [String: ChatSession] = [:]

    public init(
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
        webSearchFulfiller: (any WebSearchFulfilling)? = nil
    ) {
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
    }

    public func session(for conversationId: String) -> ChatSession {
        if let existing = sessions[conversationId] { return existing }
        let session = ChatSession(
            conversationId: conversationId,
            messageRepository: messageRepository,
            toolCallRepository: toolCallRepository,
            checkpointRepository: checkpointRepository,
            llmProviderRegistry: llmProviderRegistry,
            toolRegistry: toolRegistry,
            contextAssembler: contextAssembler,
            compactor: compactor,
            clock: clock,
            idGenerator: idGenerator,
            autoCompactEnabled: autoCompactEnabled,
            autoCompactThreshold: autoCompactThreshold,
            manualCompactMinThreshold: manualCompactMinThreshold,
            askBeforeSearching: askBeforeSearching,
            chatBriefing: chatBriefing,
            compactChatBriefing: compactChatBriefing,
            appletBriefings: appletBriefings,
            activeAppletID: activeAppletID,
            userPersonalization: currentUserPersonalization,
            memoryRepository: memoryRepository,
            webSearchFulfiller: webSearchFulfiller
        )
        sessions[conversationId] = session
        return session
    }

    /// Update existing and future sessions. Guard each fan-out hop against reentrant
    /// updates so an older call cannot overwrite a newer setting after suspension.
    public func setUserPersonalization(_ value: String) async {
        guard value != currentUserPersonalization else { return }
        currentUserPersonalization = value
        let snapshot = sessions
        for (_, session) in snapshot {
            guard currentUserPersonalization == value else { return }
            await session.setUserPersonalization(value)
        }
    }

    /// Update existing and future sessions; guard each hop against superseded policy.
    public func setAutoCompactPolicy(enabled: Bool, threshold: Double) async {
        guard enabled != autoCompactEnabled || threshold != autoCompactThreshold else {
            return
        }
        autoCompactEnabled = enabled
        autoCompactThreshold = threshold
        let snapshot = sessions
        for (_, session) in snapshot {
            guard autoCompactEnabled == enabled, autoCompactThreshold == threshold else {
                return
            }
            await session.setAutoCompactPolicy(enabled: enabled, threshold: threshold)
        }
    }

    /// Update existing and future sessions; guard each hop against superseded policy.
    public func setAskBeforeSearching(_ enabled: Bool) async {
        guard enabled != askBeforeSearching else { return }
        askBeforeSearching = enabled
        let snapshot = sessions
        for (_, session) in snapshot {
            guard askBeforeSearching == enabled else { return }
            await session.setAskBeforeSearching(enabled)
        }
    }

    /// Run once at launch before creating sessions. Fail stranded calls and synthesize missing
    /// tool-result rows so replay stays paired. Per-record failures are skipped; ContextAssembler
    /// provides a pairing fallback. Return recovered call IDs.
    @discardableResult
    public func recoverInterruptedToolCalls() async -> [String] {
        let interruptedStatuses: [ToolCallStatus] = [.pending, .executing, .awaitingConfirmation]
        var stranded: [ToolCallRecord] = []
        for status in interruptedStatuses {
            if let records = try? await toolCallRepository.fetchByStatus(status) {
                stranded.append(contentsOf: records)
            }
        }
        guard !stranded.isEmpty else { return [] }

        var resolvedCallIDs = Set<String>()
        for conversationId in Set(stranded.map(\.conversationId)) {
            guard let messages = try? await messageRepository.fetchAll(conversationId: conversationId) else {
                continue
            }
            for message in messages where message.role == .tool {
                if let callId = message.toolCallId { resolvedCallIDs.insert(callId) }
            }
        }

        var recovered: [String] = []
        for record in stranded {
            let result = ToolResult(
                toolID: record.toolName,
                content: "Tool execution was interrupted (the app quit before the tool finished). Treat this call as failed.",
                isError: true
            )
            do {
                try await toolCallRepository.updateStatus(
                    id: record.id,
                    status: .failed,
                    result: encodeJSON(result),
                    completedAt: clock.now()
                )
                if !resolvedCallIDs.contains(record.id) {
                    try await messageRepository.save(MessageRecord(
                        id: idGenerator.nextID(),
                        conversationId: record.conversationId,
                        role: .tool,
                        content: result.content,
                        toolCallId: record.id,
                        // Backdate to the call so the result sorts beside its tool_use, not after later messages.
                        createdAt: record.createdAt,
                        tokenCount: nil
                    ))
                }
                recovered.append(record.id)
            } catch {
                continue
            }
        }
        return recovered
    }

    /// Keep the session cached. Set wait to await turn wind-down before returning.
    public func cancel(for conversationId: String, wait: Bool = false) async {
        guard let session = sessions[conversationId] else { return }
        await session.cancel()
        if wait {
            await session.waitUntilFinished()
        }
    }

    /// Drain turns before dropping sessions so pending persistence can finish.
    public func shutdown() async {
        let snapshot = sessions
        for (_, session) in snapshot {
            await session.cancel()
        }
        for (_, session) in snapshot {
            await session.waitUntilFinished()
        }
        sessions.removeAll()
    }

    public func runningConversations() async -> [String] {
        let snapshot = sessions
        return await withTaskGroup(of: (String, Bool).self) { group in
            for (id, session) in snapshot {
                group.addTask {
                    let active = await session.isStreaming
                    return (id, active)
                }
            }
            var running: [String] = []
            for await (id, active) in group where active {
                running.append(id)
            }
            return running.sorted()
        }
    }
}
