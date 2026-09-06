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

    /// Client-side web-search fulfiller for non-native (`searchBackend ==
    /// "debug"`) models. `nil` in Release (and most fixtures): a stray mock
    /// backend then resolves as a declined search rather than crashing. In
    /// DEBUG the host injects `DebugWebSearchFulfiller`, and tests inject a
    /// fake — so the mock branch in `runTurnLoop` is plain, testable code
    /// rather than `#if DEBUG`.
    private let webSearchFulfiller: (any WebSearchFulfilling)?

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

    /// Canned sources/suggestions stashed by `fulfillMockSearch(_:)` on the
    /// proposal turn, drained onto the *next* assistant message (the model's
    /// grounded answer) in `streamOneTurn` — mirroring where a native
    /// provider's `.citations` land. Empty between mock searches.
    private var pendingMockSources: [SourceCitation] = []
    private var pendingMockSuggestionsHTML: String?
    /// The mock search's query, stashed alongside the sources so the grounded
    /// answer's "Web search" cell can show it even when the answer turn (a real
    /// model) emits no `.searchStarted` of its own.
    private var pendingMockQuery: String?

    /// Chat-assistant base prompt, loaded once at app launch from
    /// `Resources/DefaultSystemPrompt.md`. Hidden from the user; owned by
    /// the Chat applet author. Rendered under a `## Chat assistant`
    /// header inside the leading `.system` block. Constructor-time
    /// state — never changes during a session's lifetime.
    private let chatBriefing: String

    /// Lean persona variant sent to small-window models
    /// (`ModelContextTier.compact`), from
    /// `Resources/DefaultSystemPrompt.compact.md`. Empty means "no compact
    /// variant" — the session falls back to `chatBriefing` on every tier.
    private let compactChatBriefing: String

    /// Per-applet briefings contributed by the registered `MiniApplet`s.
    /// Trimmed and ordered by `AppletRegistry.resolvedBriefings()` at
    /// app launch and threaded through `ChatSessionStore`. Rendered as
    /// labeled `## <Name> applet` sections inside the leading `.system`
    /// block. Constructor-time state — applets are static at launch.
    /// Each entry also carries its `compactBody`, selected per turn for
    /// small-window models.
    private let appletBriefings: [AppletBriefing]

    /// Live source of the active applet's id, threaded from the shell's
    /// `AppletRegistry` (a `@MainActor` type — hence the async hop). On the
    /// compact tier the session injects **only the active applet's**
    /// briefing, since a 4096-token model can't afford rules for surfaces
    /// the user isn't on. `nil` (fixtures, single-briefing targets) keeps
    /// every briefing on every tier.
    private let activeAppletID: (@Sendable () async -> String?)?

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
        var resolvedModel: SelectableModel?
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
        /// Latest model metadata, including a context window resolved after launch.
        public let resolvedModel: SelectableModel?
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
            thinkingStartedAt: Date? = nil,
            resolvedModel: SelectableModel? = nil
        ) {
            self.accumulatedText = accumulatedText
            self.accumulatedThinking = accumulatedThinking
            self.thinkingStartedAt = thinkingStartedAt
            self.resolvedModel = resolvedModel
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
    ///   - compactChatBriefing: Lean persona variant for small-window
    ///     models, from `ChatBriefing.loadCompact()`. Default `""` falls
    ///     back to `chatBriefing` on every tier.
    ///   - appletBriefings: Per-applet prompts from
    ///     `AppletRegistry.resolvedBriefings()`. Default `[]` for
    ///     fixtures that don't construct a registry.
    ///   - activeAppletID: Live accessor for the shell's active applet id;
    ///     scopes compact-tier turns to the active applet's briefing.
    ///     Default `nil` keeps all briefings on every tier.
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
        compactChatBriefing: String = "",
        appletBriefings: [AppletBriefing] = [],
        activeAppletID: (@Sendable () async -> String?)? = nil,
        userPersonalization: String = "",
        memoryRepository: (any MemoryRepository)? = nil,
        webSearchFulfiller: (any WebSearchFulfilling)? = nil
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
            self.finishLiveTurn()
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
            self.finishLiveTurn()
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
            self.finishLiveTurn()
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
            thinkingStartedAt: live.thinkingStartedAt,
            resolvedModel: live.resolvedModel
        )
        return (snapshot, stream)
    }

    /// Yield an event to every active subscriber and update the turn's
    /// accumulators so a fresh `subscribe()` after this point reflects the
    /// latest visible state. Reset accumulators on `.assistantMessageSaved`
    /// so the next round-trip in a tool-call loop starts from `""`.
    private func broadcast(_ event: ChatEvent) {
        switch event {
        case .modelResolved(let model):
            liveTurn?.resolvedModel = model
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
        var model = model
        let nativeSearch = NativeWebSearch.usesNativeSearch(model)
        let mockSearch = NativeWebSearch.usesMockSearch(model)
        // Search-gate state for this user message's loop:
        //  - `searchApproved` → the search resolved positively. For native,
        //    subsequent turns run with the sentinel directly (proposal
        //    dropped) so the model searches and answers in one pass; for
        //    mock, it just stops re-advertising the proposal (the search was
        //    fulfilled in-process).
        //  - `searchDeclined` → the user skipped; stop offering search for the
        //    rest of this loop so the model can't re-propose in a cycle.
        // Both reset on the next `send(...)` (a fresh loop), so the gate
        // prompts again for every new user message.
        var searchApproved = false
        var searchDeclined = false
        // Clear any client-mock search stash from a prior user turn. Normally
        // `streamOneTurn` drains it onto the grounded answer, but if that turn
        // throws (LLM/stream error) before the drain, the stash would survive
        // and leak its canned sources onto an unrelated later turn (a Retry, or
        // the next message). Resetting at each turn-loop entry guarantees a
        // fresh user turn always starts clean.
        pendingMockSources = []
        pendingMockSuggestionsHTML = nil
        pendingMockQuery = nil
        while true {
            try Task.checkCancellation()
            // PCC resolves its context asynchronously. Do this before any
            // budget, briefing tier, or compaction decision uses the model.
            let priorModel = model
            model = try await provider.resolveModel(model)
            try Task.checkCancellation()
            if model != priorModel {
                broadcast(.modelResolved(SelectableModel(recordId: provider.id, model: model)))
            }
            try await maybeAutoCompact(model: model)
            let history = try await assembleHistory(model: model)
            // Small-window models (on-device AFM) drop the heaviest/lowest-value
            // tool schemas so the request fits the window — see CompactToolPolicy.
            // Applied before the per-turn web-search tools (AFM never uses those).
            var tools = CompactToolPolicy.filter(
                await toolRegistry.enabledTools(for: provider),
                tier: ModelContextTier(maxContextTokens: model.maxContextTokens)
            )
            // Per-turn search wiring:
            //  - native, gate OFF / already approved → append the sentinel so
            //    the adapter attaches its own server search tool.
            //  - native, gate ON and undecided → advertise the proposal tool
            //    so the model must ask first (no sentinel → no server search).
            //  - mock (any gate state) → advertise the proposal tool until the
            //    search resolves; never a sentinel (no real provider search).
            //  - declined / resolved → neither, so the model answers without
            //    search.
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

            // Intercept a web-search proposal — a client-side gate tool that
            // is never executed through ToolRegistry. For native, an approval
            // re-issues the turn with the sentinel; for mock, the search is
            // fulfilled in-process by the injected `WebSearchFulfilling`. Any
            // real tools the model requested alongside it still execute.
            if nativeProposalActive || mockProposalActive,
               let proposal = toolCalls.first(where: { $0.toolName == NativeWebSearch.proposalToolName }) {
                let approved: Bool
                if askBeforeSearching {
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
                } else {
                    // Mock search with the gate off: no prompt, auto-approve.
                    // (Native gate-off never reaches here — it advertises the
                    // sentinel, not the proposal tool.)
                    approved = true
                }
                if approved { searchApproved = true } else { searchDeclined = true }
                // Success path (user tapped Approve/Skip, or gate-off
                // auto-approve): unlike the cancelled-while-parked branch
                // above, these writes are *not* cancellation-shielded. If the
                // turn is cancelled in the narrow window between the
                // continuation resuming and the write committing, GRDB throws
                // at its first async hop and the `tool_use` is left without a
                // matching `tool_result` row. The window is sub-millisecond,
                // and `ContextAssembler`'s pairing-totality synthesis repairs
                // the shape on the next assembly, so this stays an accepted
                // trade-off. (`executeToolCalls` used to share this exposure;
                // it now resolves its batch tail as cancelled instead.)
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

    /// Fulfill an approved `request_web_search` proposal *client-side* for a
    /// mock-backend model: run the injected `WebSearchFulfilling`, write its
    /// findings as the tool result so the model grounds its next turn, and
    /// stash the canned sources/suggestions for `streamOneTurn` to attach to
    /// that grounded answer. With no fulfiller wired (Release, or a stray
    /// `"debug"` row) this degrades to a declined search rather than
    /// fabricating sources. Mirrors `resolveProposal`'s persistence shape.
    private func fulfillMockSearch(_ record: ToolCallRecord) async throws {
        guard let webSearchFulfiller else {
            try await resolveProposal(record, approved: false)
            return
        }
        let query = NativeWebSearch.proposedQuery(fromParametersJSON: record.parameters)
        let outcome = await webSearchFulfiller.search(query: query)

        // Stash onto the *next* assistant message (the grounded answer),
        // matching where native `.citations` land — not this proposal turn.
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
        // The enabled tool schemas are part of every request and count against
        // the window, so include them in the budget the compaction gates read.
        // `enabledTools()` (provider-agnostic) is equivalent to
        // `enabledTools(for:)` today and `assemble` has no provider in scope;
        // this counts the base registered tools, not the transient per-turn
        // web-search proposal/sentinel tools (a small, deliberate undercount).
        async let tools = toolRegistry.enabledTools()
        let tier = ModelContextTier(maxContextTokens: model.maxContextTokens)
        // Budget the SAME tier-filtered tool set the live request sends (see the
        // `runTurnLoop` filter), so the compaction gates don't over-count tools
        // a small-window model never receives.
        let budgetedTools = CompactToolPolicy.filter(await tools, tier: tier)
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
            tools: budgetedTools
        )
    }

    /// Pick the briefing stack for `tier`, per turn (not per init) so
    /// switching models mid-conversation re-tiers correctly.
    ///
    /// `.full` returns the constructor-time stack untouched — byte-identical
    /// assembly to before tiers existed. `.compact` swaps in the lean
    /// variants (falling back to the full text where no compact one exists)
    /// and, when the shell provided an `activeAppletID` accessor, keeps only
    /// the active applet's briefing — rules for surfaces the user isn't on
    /// aren't worth window on a 4096-token model. An unknown/`nil` active id
    /// fails open to the whole set.
    ///
    /// The accessor is read live on each call, so the compaction gate's
    /// assembly and the wire request's assembly within one turn could see
    /// different active applets if the user switches mid-send — a one-turn,
    /// few-hundred-token discrepancy in the budget, deliberately tolerated.
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
        // Small-window models compact earlier AND against a different
        // denominator. Their fixed floor (briefings + tool schemas + the
        // provider's own scaffolding) eats most of the window and survives
        // every checkpoint — a total-ratio gate would re-fire compaction on
        // every turn once the floor alone exceeds the threshold, without
        // ever bringing the total down. So the compact tier gates the
        // *compressible* slice (history) against the window that's actually
        // left after the floor, with the user threshold capped (not
        // replaced) at the tier ceiling so a stricter user setting wins.
        // Full-tier models keep the original total-ratio gate unchanged.
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

    /// Body of `compact(model:)` — handles the manual `/compact` ratio
    /// gate, then runs the compaction pass under `runGuardedTurn`'s
    /// shared cancellation/error mapping. Below the minimum context
    /// ratio the only event broadcast is `.error(.requestFailed(...))`;
    /// no LLM call, no checkpoint write.
    private func runCompaction(model: LLMModel) async {
        await runGuardedTurn {
            let provider = try await self.llmProviderRegistry.requireActive()
            let priorModel = model
            let model = try await provider.resolveModel(model)
            try Task.checkCancellation()
            if model != priorModel {
                self.broadcast(.modelResolved(SelectableModel(recordId: provider.id, model: model)))
            }
            let assembly = try await self.assemble(model: model)
            // Same denominator split as `maybeAutoCompact`: on the compact
            // tier the fixed floor (briefings + tools + allowance) would
            // satisfy the gate on an empty conversation, making the
            // "too short to compact" guard dead — so gate on the
            // compressible slice there.
            let tier = ModelContextTier(maxContextTokens: model.maxContextTokens)
            let gateRatio = tier == .compact ? assembly.compressibleRatio : assembly.ratio
            guard gateRatio >= self.manualCompactMinThreshold else {
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
        // Pass the conversation row id as the cache-routing affinity key — an
        // opaque, stable, PII-free local id. Only the OpenAI Chat / Responses
        // adapters act on it (and only against their first-party host); every
        // other provider's protocol-default overload ignores it.
        let stream = provider.stream(
            messages: messages,
            model: model,
            tools: tools,
            temperature: temperature,
            options: LLMRequestOptions(conversationCacheKey: conversationId)
        )

        // Reset turn-level accumulators so a late subscriber's snapshot
        // reflects this round-trip's progress, not a previous one's. The
        // tool-call loop calls `streamOneTurn` again after each tool
        // executes, and each call is its own assistant message.
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
                // Persisted alongside the thinking text so the Anthropic
                // adapter can replay the block verbatim on the next
                // tool-loop request. Not rendered, so no broadcast.
                capturedThinkingSignature = signature
            case .toolUse(_, let id, let name, let input, let signature):
                pendingCalls.append((id, name, input, signature))
            case .searchStarted(let query):
                // Capture the query for the expandable "Web search" cell. (A
                // live "Searching…" affordance via a ChatEvent is still a
                // follow-up.)
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

        if let err = streamError { throw err }

        // Cache-hit telemetry: counts only (no message content), so it stays
        // within the OBSERVABILITY.md posture. `cacheRead`/`cacheWrite` are 0
        // for providers/turns that report no cache activity. A healthy cached
        // conversation shows cacheWrite>0 on turn 1 (Anthropic) and cacheRead>0
        // from turn 2 onward.
        if let usage = capturedUsage {
            chatSessionLog.debug(
                "turn usage: input=\(usage.inputTokens, privacy: .public) output=\(usage.outputTokens, privacy: .public) cacheRead=\(usage.cacheReadInputTokens ?? 0, privacy: .public) cacheWrite=\(usage.cacheCreationInputTokens ?? 0, privacy: .public)"
            )
        }

        // Snapshot the accumulated buffers BEFORE `.assistantMessageSaved`
        // — `broadcast` resets them on that event so the next round-trip
        // in a tool-call loop starts clean. `thinkingStartedAt` reads the
        // same way: it lives on the actor so a late subscriber's snapshot
        // can carry it, and is reset on the same broadcast.
        let accumulatedText = liveTurn?.accumulatedText ?? ""
        let accumulatedThinking = liveTurn?.accumulatedThinking ?? ""
        let thinkingStartedAt = liveTurn?.thinkingStartedAt

        // Drain client-mock search results stashed by `fulfillMockSearch` on
        // the prior loop iteration onto *this* assistant message — the model's
        // grounded answer — mirroring where a native provider's `.citations`
        // land. Dedup against any stream citations with the same shared key.
        if !pendingMockSources.isEmpty || pendingMockSuggestionsHTML != nil || pendingMockQuery != nil {
            for cite in pendingMockSources {
                let key = Self.citationDedupeKey(cite.url)
                if !accumulatedSources.contains(where: { Self.citationDedupeKey($0.url) == key }) {
                    accumulatedSources.append(cite)
                }
            }
            if searchSuggestionsHTML == nil { searchSuggestionsHTML = pendingMockSuggestionsHTML }
            // The answer turn (a real model) emits no `.searchStarted`, so the
            // mock query stashed at fulfillment time is the only query source.
            if searchStartedQuery == nil { searchStartedQuery = pendingMockQuery }
            pendingMockSources = []
            pendingMockSuggestionsHTML = nil
            pendingMockQuery = nil
        }

        // Skip empty turns — the LLM yielded `.messageComplete` without
        // any text or tool calls. Persisting an empty assistant row would
        // diverge the on-disk view from `assembleHistory`'s output (which
        // drops empty rows when projecting back). Citations and the Gemini
        // suggestions HTML also count as output: a native provider can emit
        // `.citations` + `.messageComplete` with no text, and dropping the
        // turn here would lose those sources for good (they persist only on
        // this `.messageComplete` path). Thinking counts too: a
        // thinking-only turn is real model output the user watched stream
        // (and its trace re-renders from this row).
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
        // Web-search metadata for the expandable "Web search" cell. Populated
        // only when this turn actually searched (cited sources or announced a
        // query). System label: the mock/native backend, else the provider's
        // own name (the DEBUG canned provider fakes citations with no backend).
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
        // A cancellation landing between sibling `save` calls below strands
        // the already-saved calls at `.pending` (the throw unwinds before
        // `executeToolCalls` can shield them): the assembler synthesis keeps
        // the wire history valid and the launch sweep settles the status,
        // but a still-attached UI may show the chip as pending until then.
        // Accepted — closing it would need the same shield around a window
        // that is just a handful of row inserts.
        for call in pendingCalls {
            let parametersJSON = encodeJSON(call.input)
            // A provider that supplies no tool-call id would collide this PK
            // across turns: the GRDB upsert re-parents the earlier turn's row to
            // the newer message, orphaning its tool_result on replay (audit
            // P1-6). The id-less shapes are the Gemini reducer's tool-name
            // fallback (`id == name`) and an empty string (the Anthropic
            // reducer's `block.id ?? ""`). Mint a locally-unique, marked id for
            // both instead. The marker keeps the Gemini wire name-only (no
            // fabricated id), and strict providers get a unique, non-empty id
            // (no duplicate/empty `tool_use` ids). `idGenerator` makes it unique
            // even for same-turn parallel calls.
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
                // Every call in this batch already has its `tool_use`
                // persisted by `streamOneTurn`, so unwinding here would
                // orphan the in-flight call *and* every not-yet-run call
                // after it — a history strict providers reject on every
                // later turn, wedging the conversation. Write a cancelled
                // result for each before rethrowing. The writes must be
                // shielded from the turn's cancellation: GRDB's async
                // `write` throws `CancellationError` up front on an
                // already-cancelled task, so an inline `await` would no-op.
                // An unstructured `Task` does not inherit cancellation; we
                // await its completion before rethrowing (same pattern as
                // the parked-proposal path in `runTurnLoop`).
                await Task { [self] in
                    await cancelUnresolvedToolCalls(Array(records[index...]))
                }.value
                throw CancellationError()
            }
        }
    }

    /// Resolve a batch tail of tool calls as cancelled: status `.cancelled`
    /// + `completedAt`, a role-`.tool` result row so the next turn's
    /// history keeps every `tool_use` answered, and a `.toolCallCompleted`
    /// broadcast so any still-attached UI settles its chips. Mirrors
    /// `resolveProposal`'s persistence shape. Each step is best-effort
    /// (`try?`): this runs during turn teardown, where a failing write has
    /// no caller left to surface to — `ContextAssembler`'s pairing-totality
    /// synthesis backstops any row this fails to write.
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

    /// Run one tool call through `pending → executing → success/failed`,
    /// persisting the result row and broadcasting the lifecycle events.
    /// Throws `CancellationError` when the turn was cancelled — either by
    /// the registry/tool observing cancellation or by GRDB rejecting a
    /// write on the cancelled task — and `executeToolCalls` then resolves
    /// the batch tail as cancelled. Non-cancellation persistence errors
    /// propagate unshielded (the assembler's pairing-totality synthesis
    /// backstops any row they fail to write); tool *execution* errors
    /// don't throw at all — they persist as a `.failed` result.
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
            // A tool that returned normally *after* the turn was cancelled
            // must not persist a success row mid-teardown — surface the
            // cancellation instead so the batch resolves as cancelled.
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
/// silent fallback. Internal (not file-private) because
/// `ChatSessionStore.recoverInterruptedToolCalls()` persists the same
/// result shape.
func encodeJSON(_ value: ToolResult) -> String {
    // swiftlint:disable:next force_try
    let data = try! JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
}
