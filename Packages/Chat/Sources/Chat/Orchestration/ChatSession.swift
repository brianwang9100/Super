import Core
import Foundation
import os

/// Production diagnostics for `ChatSession`. Lives at file scope so
/// the actor's methods share one Logger instance. Category
/// `chat-session` so future orchestration-layer telemetry can join
/// under the same filter.
private let chatSessionLog = Logger(subsystem: "com.brianwang.Super", category: "chat-session")

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
    private let checkpointRepository: any CompactionCheckpointRepository
    private let llmProviderRegistry: LLMProviderRegistry
    private let toolRegistry: ToolRegistry
    private let contextAssembler: ContextAssembler
    private let compactor: Compactor
    private let clock: any Clock
    private let idGenerator: any IDGenerator

    /// User-preference memory store. Read once per `assemble(...)` so
    /// the very next turn sees an edit made from the Settings memory
    /// pane or via the LLM's own `memory` tool call. `nil` when the host
    /// is built without memory support (test fixtures, the live-LLM
    /// script, anything pre-M-memory).
    private let memoryRepository: (any MemoryRepository)?

    /// Auto-compaction toggle. M9 wires this to `SettingRecord(key:
    /// "autoCompactEnabled")`. When false the session never invokes
    /// `Compactor` automatically, even above the threshold; `/compact`
    /// (manual) still works.
    private var autoCompactEnabled: Bool

    /// Threshold (`tokens / model.maxContextTokens`) at which an
    /// automatic compaction fires. M9 wires this to
    /// `SettingRecord(key: "autoCompactThreshold")`; default
    /// `ChatSettings.defaultAutoCompactThreshold` (0.85).
    private var autoCompactThreshold: Double

    /// Minimum context-usage ratio below which manual `/compact` refuses
    /// and emits a user-facing `.error(.requestFailed(...))` event. Below
    /// this the summary would be too short to justify the round-trip.
    /// Injectable for tests; production constructs default to
    /// `ChatSettings.defaultManualCompactMinThreshold` (0.30).
    private let manualCompactMinThreshold: Double

    /// Native web-search cost gate. When `true` (the default), a
    /// native-search model must *propose* each search via
    /// `request_web_search` and wait for the user to approve it before any
    /// billable search runs; when `false`, native search is enabled
    /// directly from turn one with no prompt. Only affects models whose
    /// `searchBackend == "native"`. Mutable so a Settings toggle fans out
    /// to a long-running session via `setAskBeforeSearching(_:)`.
    private var askBeforeSearching: Bool

    /// In-flight `request_web_search` proposals keyed by tool-call id, each
    /// holding the continuation `runTurnLoop` is suspended on. Resolved by
    /// `confirmToolCall(id:)`/`skipToolCall(id:)` (user decision) or
    /// `cancelPendingConfirmation(id:)` (turn cancellation). Empty between
    /// gated searches.
    private var pendingConfirmations: [String: CheckedContinuation<Bool, Error>] = [:]

    /// Chat-assistant base prompt, loaded once at app launch from
    /// `Resources/DefaultSystemPrompt.md`. Hidden from the user; owned by
    /// the Chat applet author. Rendered under a `## Chat assistant`
    /// header inside the leading `.system` block. Constructor-time
    /// state — never changes during a session's lifetime.
    private let chatBriefing: String

    /// Per-applet briefings contributed by the registered `MiniApplet`s.
    /// Trimmed and ordered by `AppletRegistry.resolvedBriefings()` at
    /// app launch and threaded through `ChatSessionStore`. Rendered as
    /// labeled `## <Name> applet` sections inside the leading `.system`
    /// block. Constructor-time state — applets are static at launch.
    private let appletBriefings: [AppletBriefing]

    /// User-authored personalization text (formerly the user-editable
    /// "system prompt"). Free-form preferences about themselves the
    /// assistant should keep in mind. Rendered under a
    /// `## User personalization` header at the *end* of the leading
    /// system block so it follows — never overrides — the authoritative
    /// chat and applet sections. Mutated at runtime via
    /// `setUserPersonalization(_:)` so a Settings UI edit takes effect on
    /// the very next turn.
    private var currentUserPersonalization: String

    /// The in-flight turn's task, or `nil` between turns. Cleared from
    /// inside `run`'s `defer` so `isStreaming` flips back to `false` as
    /// soon as the work finishes (and so a subsequent `send(...)` doesn't
    /// pointlessly await an already-completed task).
    private var currentTask: Task<Void, Never>?

    /// Per-turn fan-out state. Non-nil while a turn is in flight: holds
    /// the accumulators that a late-attaching subscriber reads via
    /// `subscribe()` to hydrate, plus every active subscriber's
    /// continuation so `broadcast(...)` can yield to all of them.
    /// Reset to `nil` in `finishLiveTurn()` after the turn winds down.
    private var liveTurn: LiveTurn?

    private struct LiveTurn {
        var accumulatedText: String = ""
        var accumulatedThinking: String = ""
        /// Wall-clock instant of the first thinking delta in the current
        /// round-trip. Held on the actor (not a local in `streamOneTurn`)
        /// so a late-attaching subscriber's snapshot carries the original
        /// start time — otherwise the "Thought for Xs" counter would reset
        /// every time a view model detached and re-attached. Reset to
        /// `nil` alongside the accumulators on `.assistantMessageSaved` so
        /// the next round-trip in a tool-call loop starts fresh.
        var thinkingStartedAt: Date?
        var subscribers: [UUID: AsyncStream<ChatEvent>.Continuation] = [:]
    }

    /// Snapshot of the in-flight turn's accumulated text/thinking,
    /// returned alongside the live event stream by `subscribe()`. Lets a
    /// late attacher hydrate its view to the current state so the user
    /// sees the in-progress response, not a blank slate.
    public struct LiveTurnSnapshot: Sendable {
        public let accumulatedText: String
        public let accumulatedThinking: String
        /// Wall-clock instant of the first thinking delta in this
        /// round-trip, or `nil` if no thinking has been emitted yet. The
        /// view layer uses this to drive the "Thought for Xs" elapsed
        /// counter so re-attaching to an in-flight turn doesn't reset it
        /// to zero.
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

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - clock: Injected so tests can substitute a `FixedClock` and
    ///     assert deterministic `createdAt` timestamps on persisted rows.
    ///     The repository ordering uses `(createdAt, rowid)` so a true
    ///     fixed clock still yields deterministic history order.
    ///   - idGenerator: Injected so tests can substitute a
    ///     `DeterministicIDGenerator` and assert exact `MessageRecord` ids.
    ///   - autoCompactEnabled: Whether the session automatically compacts
    ///     before turns when over `autoCompactThreshold`. Default `true`.
    ///   - autoCompactThreshold: Fraction of `model.maxContextTokens` at
    ///     which auto-compaction kicks in. Default
    ///     `ChatSettings.defaultAutoCompactThreshold`.
    ///   - manualCompactMinThreshold: Minimum context-usage ratio below
    ///     which manual `/compact` refuses and emits a user-facing error.
    ///     Default `ChatSettings.defaultManualCompactMinThreshold`. Tests
    ///     can pass `0.0` to bypass the gate when exercising the
    ///     happy-path body.
    ///   - chatBriefing: Chat-assistant base prompt, loaded once at app
    ///     launch from `Resources/DefaultSystemPrompt.md`. Default `""`
    ///     so fixtures that don't carry the Chat bundle keep working.
    ///   - appletBriefings: Per-applet prompts from
    ///     `AppletRegistry.resolvedBriefings()`. Default `[]` for
    ///     fixtures that don't construct a registry.
    ///   - userPersonalization: User-authored "about me" text — the
    ///     renamed `ChatSettings.systemPrompt` field. Default `""`
    ///     (no injection) for fixtures that don't carry settings.
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
        appletBriefings: [AppletBriefing] = [],
        userPersonalization: String = "",
        memoryRepository: (any MemoryRepository)? = nil
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
        self.appletBriefings = appletBriefings
        self.currentUserPersonalization = userPersonalization
        self.memoryRepository = memoryRepository
    }

    /// Update the auto-compaction policy at runtime. M9's settings pane
    /// calls this when the user flips the toggle or moves the threshold
    /// slider so a long-running session picks up the new policy on its
    /// next turn.
    public func setAutoCompactPolicy(enabled: Bool, threshold: Double) {
        self.autoCompactEnabled = enabled
        self.autoCompactThreshold = threshold
    }

    /// Update the native web-search cost-gate policy at runtime. The
    /// Settings → Search pane calls this (via `ChatSessionStore`) so a
    /// long-running session picks up the toggle on its next turn. Does not
    /// affect a search proposal already parked at `.awaitingConfirmation` —
    /// that one still waits for the user's explicit decision.
    public func setAskBeforeSearching(_ enabled: Bool) {
        self.askBeforeSearching = enabled
    }

    /// Approve a parked `request_web_search` proposal so the turn loop
    /// re-issues with native search enabled. No-ops if the id isn't
    /// awaiting confirmation (already resolved, cancelled, or never parked),
    /// so a double-tap or a stale UID is harmless.
    public func confirmToolCall(id: String) {
        if let continuation = pendingConfirmations.removeValue(forKey: id) {
            continuation.resume(returning: true)
        }
    }

    /// Decline a parked `request_web_search` proposal so the turn loop
    /// continues without search. Same idempotent no-op contract as
    /// `confirmToolCall(id:)`.
    public func skipToolCall(id: String) {
        if let continuation = pendingConfirmations.removeValue(forKey: id) {
            continuation.resume(returning: false)
        }
    }

    /// Resolve a parked proposal as cancelled (turn cancellation) by
    /// throwing `CancellationError` into the suspended `runTurnLoop`. Routed
    /// through the same registry so confirm/skip/cancel can't double-resume
    /// one continuation.
    private func cancelPendingConfirmation(id: String) {
        if let continuation = pendingConfirmations.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        }
    }

    /// Update the user personalization text at runtime. The Settings UI
    /// calls this (via `ChatSessionStore.setUserPersonalization`) when
    /// the user edits the field so a long-running session picks up the
    /// new value on its next turn — current setting always wins over
    /// what the session was constructed with.
    public func setUserPersonalization(_ value: String) {
        self.currentUserPersonalization = value
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
    ///
    /// Slash commands (e.g. `/compact`) are recognized at submission and
    /// dispatched in place of a user turn — no `MessageRecord` is written
    /// for the slash command itself.
    public func send(
        text: String,
        model: LLMModel,
        references: [RecordReference] = [],
        temperature: Double = 1.0
    ) async -> AsyncStream<ChatEvent> {
        if let command = SlashCommand(rawText: text) {
            return await dispatch(command: command, model: model)
        }

        if let prior = currentTask {
            prior.cancel()
            await prior.value
        }

        liveTurn = LiveTurn()
        let subscription = subscribe()
        let task = Task {
            await self.run(userText: text, references: references, model: model, temperature: temperature)
            await self.finishLiveTurn()
        }
        currentTask = task
        // Intentionally no per-iterator cancel hook. The turn's lifetime
        // is owned by the actor (cancellable via `cancel()`), not by
        // whoever happens to be iterating a returned stream. Multiple
        // consumers can attach in parallel via `subscribe()` so a UI
        // view-model swap can keep streaming the same turn.
        return subscription.stream
    }

    /// Re-run the LLM loop for this conversation against the
    /// already-persisted transcript. Used by the Chat UI's Retry pill
    /// after an LLM error: the failed user `MessageRecord` is still on
    /// disk from the failed turn, so retry must **not** create a second
    /// one. Same prior-turn fence + `liveTurn`/subscribe wiring as
    /// `send(...)`. If no user message exists yet for this conversation,
    /// the stream finishes with no events (silent no-op).
    public func retry(
        model: LLMModel,
        temperature: Double = 1.0
    ) async -> AsyncStream<ChatEvent> {
        if let prior = currentTask {
            prior.cancel()
            await prior.value
        }

        liveTurn = LiveTurn()
        let subscription = subscribe()
        let task = Task {
            await self.runRetry(model: model, temperature: temperature)
            await self.finishLiveTurn()
        }
        currentTask = task
        return subscription.stream
    }

    /// Manually invoke a compaction pass. Returns an `AsyncStream` so the
    /// composer can render the same `.compactionStarted` /
    /// `.compactionCompleted` UI it shows for auto-compaction. If a turn
    /// is in flight, this fences on it before starting (same lock-step
    /// guarantee as `send(...)`). When there's nothing to summarize the
    /// stream just closes — no `.compactionStarted` event fires, so the
    /// UI doesn't flash a banner that has nothing behind it.
    public func compact(model: LLMModel) async -> AsyncStream<ChatEvent> {
        if let prior = currentTask {
            prior.cancel()
            await prior.value
        }

        liveTurn = LiveTurn()
        let subscription = subscribe()
        let task = Task {
            await self.runCompaction(model: model)
            await self.finishLiveTurn()
        }
        currentTask = task
        return subscription.stream
    }

    /// Attach to the in-flight turn (if any). Returns a snapshot of the
    /// current accumulated text/thinking plus a fresh `AsyncStream` that
    /// carries every subsequent `ChatEvent` for this turn. When no turn
    /// is in flight the snapshot is `nil` and the stream finishes
    /// immediately — callers should fall back to the persisted transcript.
    ///
    /// Multiple subscribers can be active simultaneously; each receives
    /// the same events. When a subscriber's stream goes out of scope its
    /// continuation's `onTermination` removes it from the fan-out — the
    /// turn itself is unaffected.
    public func subscribe() -> (snapshot: LiveTurnSnapshot?, stream: AsyncStream<ChatEvent>) {
        let (stream, continuation) = AsyncStream<ChatEvent>.makeStream()
        // Bind to a local copy so the snapshot reads below are safe even
        // if a future refactor introduces a suspension point between the
        // guard and the dictionary write. The mutation itself uses
        // optional-chain (`liveTurn?.subscribers[id] = ...`) for the same
        // reason — no force-unwraps to maintain.
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

    /// Yield an event to every active subscriber and update the turn's
    /// accumulators so a fresh `subscribe()` after this point reflects the
    /// latest visible state. Reset accumulators on `.assistantMessageSaved`
    /// so the next round-trip in a tool-call loop starts from `""`.
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

    /// Finish every active subscriber's stream and clear the turn state.
    /// Called from the spawned task once the run loop returns (success,
    /// error, or cancellation).
    private func finishLiveTurn() {
        if let subscribers = liveTurn?.subscribers {
            for (_, continuation) in subscribers {
                continuation.finish()
            }
        }
        liveTurn = nil
    }

    /// Drop a subscriber whose iterator has been released. Safe to call
    /// after `finishLiveTurn()` — the `liveTurn` optional-chain no-ops.
    private func removeSubscriber(id: UUID) {
        liveTurn?.subscribers.removeValue(forKey: id)
    }

    private func dispatch(command: SlashCommand, model: LLMModel) async -> AsyncStream<ChatEvent> {
        switch command {
        case .compact:
            return await compact(model: model)
        }
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
                // `encode` returns nil for an empty set, so a message
                // without verse pills leaves the column NULL.
                attachmentsJSON: MessageRecord.encode(MessageAttachments(references: references))
            )
            try await self.messageRepository.save(userMessage)
            self.broadcast(.userMessageSaved(userMessage))

            let provider = try await self.llmProviderRegistry.requireActive()
            try await self.runTurnLoop(model: model, temperature: temperature, provider: provider)
        }
    }

    /// Body of `retry(model:temperature:)` — resolves the provider and
    /// re-enters the turn loop against the persisted transcript. Silently
    /// no-ops (no broadcast, no rows written) when the conversation has
    /// no user message yet, so a stray tap on a stale Retry pill can't
    /// flash a bogus error.
    private func runRetry(model: LLMModel, temperature: Double) async {
        await runGuardedTurn {
            // O(1) predicate rather than `fetchAll` — `runTurnLoop` will
            // load the full history via `assembleHistory` moments later,
            // so a second materialization here would double the work for
            // every retry on a long conversation.
            guard try await self.messageRepository.hasUserMessage(conversationId: self.conversationId) else {
                return
            }

            let provider = try await self.llmProviderRegistry.requireActive()
            try await self.runTurnLoop(model: model, temperature: temperature, provider: provider)
        }
    }

    /// Run a turn-shaped body inside the shared error→event mapping that
    /// every entry point into the turn loop needs: `CancellationError`
    /// becomes `.error(.cancelled)`, `LLMError` and `LLMProviderRegistryError`
    /// get user-facing copy, and any other throw is reported as
    /// `.requestFailed(...)`. Also clears `currentTask` on the way out so
    /// `isStreaming` flips back to `false` as soon as the work finishes —
    /// previously each call site duplicated this with its own `defer` and
    /// its own 14-line `catch` ladder, which would silently drift if a new
    /// error type were added on one side and not the other.
    private func runGuardedTurn(_ body: () async throws -> Void) async {
        defer { currentTask = nil }
        do {
            try await body()
        } catch is CancellationError {
            broadcast(.error(.cancelled))
        } catch let err as LLMError {
            broadcast(.error(err))
        } catch let err as CompactorError {
            // Auto-compaction (triggered inside `runTurnLoop` via
            // `maybeAutoCompact`) can fail with its own typed error. Map
            // it with curated copy here so a send/retry that hits the
            // auto-compact path before reaching the LLM doesn't fall
            // through to the generic `localizedDescription`. Matches the
            // mapping in `runCompaction` (manual `/compact`).
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

    /// The provider-streaming loop shared by `run(userText:...)` and
    /// `runRetry(...)`. Assembles history, streams a turn, executes any
    /// requested tool calls, and repeats until the model emits a turn
    /// with no tool calls.
    private func runTurnLoop(
        model: LLMModel,
        temperature: Double,
        provider: LLMProvider
    ) async throws {
        let nativeSearch = NativeWebSearch.usesNativeSearch(model)
        // Search-gate state for this user message's loop:
        //  - `searchApproved` → the user approved; subsequent turns run with
        //    native search enabled directly (proposal dropped) so the model
        //    searches and answers in one pass.
        //  - `searchDeclined` → the user skipped; stop offering search for the
        //    rest of this loop so the model can't re-propose in a cycle.
        // Both reset on the next `send(...)` (a fresh loop), so the gate
        // prompts again for every new user message.
        var searchApproved = false
        var searchDeclined = false
        while true {
            try Task.checkCancellation()
            try await maybeAutoCompact(model: model)
            let history = try await assembleHistory(model: model)
            var tools = await toolRegistry.enabledTools(for: provider)
            // Per-turn search wiring, native-search models only:
            //  - gate OFF, or already approved → append the sentinel so the
            //    adapter attaches its own server search tool.
            //  - gate ON and undecided → advertise the proposal tool so the
            //    model must ask first (no sentinel → no server search).
            //  - gate ON and declined → neither, so the model answers without
            //    search.
            let gateActive = nativeSearch && askBeforeSearching && !searchApproved && !searchDeclined
            if nativeSearch {
                if !askBeforeSearching || searchApproved {
                    tools.append(NativeWebSearch.sentinelTool)
                } else if !searchDeclined {
                    tools.append(NativeWebSearch.proposalTool)
                }
            }
            let toolCalls = try await streamOneTurn(
                provider: provider,
                messages: history,
                model: model,
                tools: tools,
                temperature: temperature
            )
            if toolCalls.isEmpty { return }

            // Intercept a web-search proposal — a client-side gate tool that
            // is never executed through ToolRegistry. Park it for approval,
            // write its tool result, then loop: an approval re-issues the
            // turn with the sentinel attached. Any real tools the model
            // requested alongside it still execute normally.
            if gateActive,
               let proposal = toolCalls.first(where: { $0.toolName == NativeWebSearch.proposalToolName }) {
                let approved: Bool
                do {
                    approved = try await awaitSearchDecision(for: proposal)
                } catch {
                    // The turn was cancelled while the proposal was parked.
                    // Still write a (declined) tool result before unwinding so
                    // the persisted `tool_use` isn't left orphaned — a
                    // `tool_use` with no matching `tool_result` is replayed on
                    // the next turn's history and rejected by the provider,
                    // wedging the conversation. The write must be shielded from
                    // the turn's cancellation: GRDB's async `write` throws
                    // `CancellationError` up front on an already-cancelled task,
                    // so an inline `await` here would no-op. An unstructured
                    // `Task` does not inherit cancellation, so its writes run to
                    // completion; we await its result before rethrowing.
                    await Task { [self] in
                        try? await resolveProposal(proposal, approved: false)
                    }.value
                    throw error
                }
                if approved { searchApproved = true } else { searchDeclined = true }
                try await resolveProposal(proposal, approved: approved)
                let others = toolCalls.filter { $0.id != proposal.id }
                if !others.isEmpty { try await executeToolCalls(others) }
                continue
            }

            try await executeToolCalls(toolCalls)
        }
    }

    /// Park a `request_web_search` proposal at `.awaitingConfirmation`,
    /// broadcast the event that drives the inline confirm row, and suspend
    /// the turn until the user decides. Returns `true` to run the search,
    /// `false` to skip it. Throws `CancellationError` if the turn is
    /// cancelled while waiting — `cancelPendingConfirmation(id:)`, invoked
    /// from the cancellation handler, resumes the continuation. The
    /// actor's serialized execution closes the store-vs-cancel race: the
    /// cancel hop can't run until this method has suspended (and thus stored
    /// the continuation), so it always finds the entry to resolve.
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
                // A cancellation that landed before we suspended must not
                // orphan the continuation — bail immediately.
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

    /// Write the tool result for a resolved `request_web_search` proposal so
    /// the next turn's rebuilt history is well-formed — every `tool_use`
    /// needs a matching `tool_result`. Approved → status `.success` + a
    /// "search now and cite" result; declined → status `.cancelled` + an
    /// "answer from your own knowledge" result. Both persist a role-`.tool`
    /// `MessageRecord` and broadcast `.toolCallCompleted` so the inline
    /// confirm row settles.
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

    /// Project the on-disk records back into the LLM-facing message shape
    /// via `ContextAssembler`. The live `CompactionCheckpointRecord`
    /// (when present) is folded in as a leading system message; messages
    /// covered by the checkpoint are dropped from the prompt.
    private func assembleHistory(model: LLMModel) async throws -> [LLMMessage] {
        try await assemble(model: model).messages
    }

    private func assemble(model: LLMModel) async throws -> ContextAssembly {
        async let messages = messageRepository.fetchAll(conversationId: conversationId)
        async let toolCalls = toolCallRepository.fetchByConversation(conversationId)
        async let checkpoint = checkpointRepository.liveCheckpoint(for: conversationId)
        async let memories = currentMemories()
        return try await contextAssembler.assemble(
            messages: messages,
            toolCalls: toolCalls,
            checkpoint: checkpoint,
            model: model,
            chatBriefing: chatBriefing,
            appletBriefings: appletBriefings,
            userPersonalization: currentUserPersonalization,
            memories: memories
        )
    }

    /// Fetch stored memories when the `memory` tool is enabled, otherwise
    /// `[]`. Disabled-tool branch returns immediately without touching
    /// the repository so an off toggle has zero query cost.
    ///
    /// Returns full `MemoryEntry` values (not just text) so the
    /// downstream block renderer can surface each id to the LLM —
    /// required for `memory(op:'update'|'forget', id:...)` to work in
    /// conversations where the model didn't perform the original
    /// `save` and therefore has no other id source.
    ///
    /// A repository read failure (transient GRDB error, WAL lock,
    /// schema migration in progress) falls back to `[]` rather than
    /// throwing — losing the memories block for one turn is preferable
    /// to failing the entire turn. The failure is logged so a recurring
    /// fault surfaces in `os_log` instead of silently wiping the user's
    /// stored preferences from every prompt.
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

    /// Auto-compaction gate. Called before every turn within the run loop.
    /// Skips silently when disabled, when not over threshold, or when the
    /// compactor returns nil (nothing worth summarizing yet). On success
    /// emits `.compactionStarted` then `.compactionCompleted` so the UI
    /// can render the same banner it shows for `/compact`. Keeps the
    /// trailing `Compactor.defaultKeepMostRecent` messages verbatim so the
    /// next assistant turn retains full-fidelity recent context.
    private func maybeAutoCompact(model: LLMModel) async throws {
        guard autoCompactEnabled else { return }
        let assembly = try await assemble(model: model)
        guard assembly.isOverThreshold(autoCompactThreshold) else { return }
        try await runCompactionPass(model: model, keepMostRecent: Compactor.defaultKeepMostRecent)
    }

    /// Body of `compact(model:)` — handles the manual `/compact` ratio
    /// gate, then runs the compaction pass under `runGuardedTurn`'s
    /// shared cancellation/error mapping. Below the minimum context
    /// ratio the only event broadcast is `.error(.requestFailed(...))`;
    /// no LLM call, no checkpoint write.
    private func runCompaction(model: LLMModel) async {
        await runGuardedTurn {
            let assembly = try await self.assemble(model: model)
            guard assembly.ratio >= self.manualCompactMinThreshold else {
                let pct = Int((self.manualCompactMinThreshold * 100).rounded())
                self.broadcast(.error(.requestFailed(
                    "Conversation is too short to compact yet — try again once context usage reaches \(pct)%."
                )))
                return
            }
            // Manual `/compact` summarizes everything up to now — no
            // trailing carve-out. The persisted checkpoint's
            // `uptoMessageId` becomes the last message on disk, so the
            // banner anchors at the bottom of the transcript and matches
            // the user's "I compacted everything" mental model.
            try await self.runCompactionPass(model: model, keepMostRecent: 0)
        }
    }

    /// Shared compaction worker. Used by both auto-compaction (inside the
    /// turn loop) and manual `/compact`. Emits `.compactionStarted`
    /// **only** after the compactor commits to running — when there's
    /// nothing to summarize we return without firing any events so the
    /// UI doesn't flash a banner that immediately disappears.
    ///
    /// - Parameter keepMostRecent: How many trailing messages to leave
    ///   outside the summary window. Auto-compaction passes
    ///   `Compactor.defaultKeepMostRecent` to preserve immediate-context
    ///   fidelity for the next turn; manual `/compact` passes `0` so the
    ///   entire conversation is summarized and the banner lands at the
    ///   bottom of the transcript.
    private func runCompactionPass(model: LLMModel, keepMostRecent: Int) async throws {
        let messages = try await messageRepository.fetchAll(conversationId: conversationId)
        let toolCalls = try await toolCallRepository.fetchByConversation(conversationId)
        let prior = try await checkpointRepository.liveCheckpoint(for: conversationId)

        // Skip silently when there's nothing to summarize. Pure predicate
        // (no LLM call) sharing slicing rules with `Compactor.compact` so
        // the two paths cannot disagree.
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
        // Pre-flight committed `wouldCompact` to true; an actual nil here
        // means the two slicing rules drifted — programmer error, not a
        // user-facing condition. `assertionFailure` rather than `.error`
        // surfaces it loudly in tests/debug without crashing release.
        guard let checkpoint else {
            assertionFailure("Compactor.wouldCompact disagreed with Compactor.compact — slicing logic drifted")
            return
        }
        broadcast(.compactionCompleted(checkpoint))
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
        temperature: Double
    ) async throws -> [ToolCallRecord] {
        let stream = provider.stream(
            messages: messages,
            model: model,
            tools: tools,
            temperature: temperature
        )

        // Reset turn-level accumulators so a late subscriber's snapshot
        // reflects this round-trip's progress, not a previous one's. The
        // tool-call loop calls `streamOneTurn` again after each tool
        // executes, and each call is its own assistant message.
        liveTurn?.accumulatedText = ""
        liveTurn?.accumulatedThinking = ""
        liveTurn?.thinkingStartedAt = nil
        var thinkingEndedAt: Date?
        var pendingCalls: [(id: String, name: String, input: JSONValue)] = []
        var capturedUsage: TokenUsage?
        var streamError: LLMError?
        var accumulatedSources: [SourceCitation] = []
        var searchSuggestionsHTML: String?

        for try await event in stream {
            try Task.checkCancellation()
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
            case .toolUse(_, let id, let name, let input):
                pendingCalls.append((id, name, input))
            case .searchStarted:
                // PR1 captures-and-persists citations only; a live "Searching…"
                // affordance via a ChatEvent is a follow-up.
                break
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

        if let err = streamError { throw err }

        // Snapshot the accumulated buffers BEFORE `.assistantMessageSaved`
        // — `broadcast` resets them on that event so the next round-trip
        // in a tool-call loop starts clean. `thinkingStartedAt` reads the
        // same way: it lives on the actor so a late subscriber's snapshot
        // can carry it, and is reset on the same broadcast.
        let accumulatedText = liveTurn?.accumulatedText ?? ""
        let accumulatedThinking = liveTurn?.accumulatedThinking ?? ""
        let thinkingStartedAt = liveTurn?.thinkingStartedAt

        // Skip empty turns — the LLM yielded `.messageComplete` without
        // any text or tool calls. Persisting an empty assistant row would
        // diverge the on-disk view from `assembleHistory`'s output (which
        // drops empty rows when projecting back). Citations and the Gemini
        // suggestions HTML also count as output: a native provider can emit
        // `.citations` + `.messageComplete` with no text, and dropping the
        // turn here would lose those sources for good (they persist only on
        // this `.messageComplete` path).
        if accumulatedText.isEmpty,
           pendingCalls.isEmpty,
           accumulatedSources.isEmpty,
           searchSuggestionsHTML == nil {
            return []
        }

        let thinkingDurationMs: Int? = {
            guard let start = thinkingStartedAt, let end = thinkingEndedAt else { return nil }
            return max(0, Int(end.timeIntervalSince(start) * 1000))
        }()
        let attachments = MessageAttachments(
            sources: accumulatedSources,
            searchSuggestionsHTML: searchSuggestionsHTML
        )
        let assistantMessage = MessageRecord(
            id: idGenerator.nextID(),
            conversationId: conversationId,
            role: .assistant,
            content: accumulatedText,
            thinkingContent: accumulatedThinking.isEmpty ? nil : accumulatedThinking,
            thinkingDurationMs: thinkingDurationMs,
            toolCallId: nil,
            createdAt: clock.now(),
            tokenCount: capturedUsage?.outputTokens,
            attachmentsJSON: MessageRecord.encode(attachments)
        )
        try await messageRepository.save(assistantMessage)
        broadcast(.assistantMessageSaved(assistantMessage))

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
            broadcast(.toolCallStarted(record))
            savedCalls.append(record)
        }

        return savedCalls
    }

    private func executeToolCalls(_ records: [ToolCallRecord]) async throws {
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
