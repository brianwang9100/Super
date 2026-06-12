import Core
import Foundation

/// App-level coordinator that owns one `ChatSession` per conversation.
/// The store is a singleton in production; tests construct it directly.
///
/// Multiple sessions stream in parallel without sharing state — cancelling
/// one session never affects siblings, and a session's lifecycle outlives
/// the view model that started it (so switching away from a streaming chat
/// doesn't drop the response).
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
    /// Current auto-compaction toggle. Mutable so a slider/toggle change
    /// in Settings → Compaction can fan out to active sessions and seed
    /// any session created afterward — see `setAutoCompactPolicy(...)`.
    private var autoCompactEnabled: Bool
    /// Current auto-compaction threshold (fraction of context window).
    /// Same mutability rationale as `autoCompactEnabled`.
    private var autoCompactThreshold: Double
    private let manualCompactMinThreshold: Double
    /// Current native web-search cost-gate toggle ("Ask before each
    /// search"). Mutable so a Settings change fans out to active sessions
    /// and seeds sessions created afterward — see `setAskBeforeSearching(_:)`.
    private var askBeforeSearching: Bool
    /// Chat-assistant base prompt. Constructor-time state — the Chat
    /// applet author owns its content; no runtime setter.
    private let chatBriefing: String
    /// Lean persona variant for small-window models (see
    /// `ChatSession.compactChatBriefing`). Constructor-time state.
    private let compactChatBriefing: String
    /// Per-applet briefings (already trimmed and sorted by `appletID`),
    /// each carrying its compact body. Constructor-time state — applets
    /// are static at app launch.
    private let appletBriefings: [AppletBriefing]
    /// Live active-applet accessor handed to each session (see
    /// `ChatSession.activeAppletID`). Constructor-time state.
    private let activeAppletID: (@Sendable () async -> String?)?
    /// Current user-personalization text (was `currentSystemPrompt`).
    /// Mutated via `setUserPersonalization(_:)` and fanned out to every
    /// active session.
    private var currentUserPersonalization: String
    /// Stored memories source handed to each session it constructs.
    /// `nil` when the host wires the store without memory support
    /// (test fixtures, the live-LLM script). See ``ChatSession``'s
    /// `memoryRepository` for the per-session contract.
    private let memoryRepository: (any MemoryRepository)?
    /// Client-side web-search fulfiller handed to each session it constructs.
    /// `nil` in Release and most fixtures; in DEBUG the host injects
    /// `DebugWebSearchFulfiller` so the `"debug"` mock backend works in the
    /// simulator. Constructor-time state — no runtime setter.
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

    /// Get-or-create the session for a conversation. Subsequent calls with
    /// the same id return the same instance, so a streaming turn started
    /// in one view re-attaches when the view re-mounts.
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

    /// Push a new user-personalization value to every active session and
    /// remember it as the default for sessions created later. The
    /// Settings UI calls this whenever the user edits the field so
    /// long-running sessions pick up the new value on their next turn —
    /// including ones the user returns to after the edit. No-ops if the
    /// value is unchanged.
    ///
    /// The per-session `await` inside the fan-out loop suspends this actor,
    /// which means a concurrent `setUserPersonalization("B")` arriving
    /// mid-loop can interleave: it correctly updates
    /// `currentUserPersonalization` and fans "B" out to every session,
    /// then this loop's continuation resumes and would silently overwrite
    /// the trailing sessions with the stale `value`. The intra-loop
    /// `guard currentUserPersonalization == value` bails early once the
    /// value has been superseded — last write wins, all sessions agree
    /// with `currentUserPersonalization` once both calls return.
    public func setUserPersonalization(_ value: String) async {
        guard value != currentUserPersonalization else { return }
        currentUserPersonalization = value
        let snapshot = sessions
        for (_, session) in snapshot {
            guard currentUserPersonalization == value else { return }
            await session.setUserPersonalization(value)
        }
    }

    /// Push a new auto-compaction policy to every active session and
    /// remember it as the default for sessions created later. The
    /// Settings → Compaction pane calls this after persisting the toggle
    /// or threshold slider, so a long-running session picks up the new
    /// policy on its next turn (and brand-new sessions seed with the
    /// latest values, not the boot-time ones). No-ops when the
    /// `(enabled, threshold)` pair is unchanged.
    ///
    /// Concurrency rationale mirrors `setSystemPrompt(_:)` exactly: the
    /// per-session `await` suspends the actor, a racing call can
    /// interleave, and the intra-loop guard against the live
    /// `(autoCompactEnabled, autoCompactThreshold)` snapshot bails out
    /// early once the values have been superseded — last write wins, all
    /// sessions agree with the store once both calls return.
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

    /// Push a new native web-search cost-gate toggle to every active session
    /// and remember it as the default for sessions created later. The
    /// Settings → Search pane calls this after persisting the toggle. No-ops
    /// when unchanged. Concurrency rationale mirrors `setAutoCompactPolicy`:
    /// the per-session `await` suspends the actor, a racing call interleaves,
    /// and the intra-loop guard against the live value bails out once
    /// superseded — last write wins.
    public func setAskBeforeSearching(_ enabled: Bool) async {
        guard enabled != askBeforeSearching else { return }
        askBeforeSearching = enabled
        let snapshot = sessions
        for (_, session) in snapshot {
            guard askBeforeSearching == enabled else { return }
            await session.setAskBeforeSearching(enabled)
        }
    }

    /// Resolve tool calls stranded at a non-terminal status by a crash or
    /// force-quit: mark them `.failed` with an "interrupted" result and
    /// synthesize the missing role-`.tool` result row, so every persisted
    /// `tool_use` stays answered and the conversation's next turn projects
    /// a provider-valid history. Call once at launch, **before** the first
    /// `session(for:)` — no session exists yet, so the sweep cannot race a
    /// live turn. A non-terminal status is the evidence of interruption;
    /// rows are only inserted when genuinely missing (a crash can land
    /// between the message write and the status update, in either order).
    /// Per-record failures are skipped (best-effort): `ContextAssembler`'s
    /// pairing-totality synthesis backstops any row this misses.
    ///
    /// - Returns: The ids of the recovered tool calls (for logging/tests).
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

        // One fetch per conversation to detect which calls already have a
        // persisted result row.
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
                        // Backdated to the call's creation time, NOT the
                        // sweep time: `fetchAll` orders by (createdAt,
                        // rowid), and rows may have landed after the
                        // stranded call (a wedged conversation keeps
                        // accumulating user rows). A launch-time stamp
                        // would sort the result after them — out of
                        // position next to its `tool_use` on the wire,
                        // which strict providers reject. The call's own
                        // timestamp is ≥ its parent assistant row's and
                        // < everything later, so the pair stays adjacent
                        // (rowid breaks the tie with the assistant row).
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

    /// Cancel the session's current turn, if any. The session itself stays
    /// in the store so a subsequent `session(for:)` returns the same
    /// instance. Returns immediately; pass `wait: true` to await the
    /// session's wind-down (mirrors `ChatSession.cancel()` +
    /// `waitUntilFinished()`).
    public func cancel(for conversationId: String, wait: Bool = false) async {
        guard let session = sessions[conversationId] else { return }
        await session.cancel()
        if wait {
            await session.waitUntilFinished()
        }
    }

    /// Cancel every session, await each one's wind-down, and drop them.
    /// Call on app shutdown so in-flight GRDB writes settle before the
    /// process exits (otherwise SQLite has to recover on next launch).
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

    /// Identifiers of conversations whose session currently has an in-flight turn.
    /// The sidebar reads this for the per-row running spinner. Polls each
    /// session in parallel via `withTaskGroup` so a 50-conversation store
    /// doesn't pay 50 serial actor hops per refresh.
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
