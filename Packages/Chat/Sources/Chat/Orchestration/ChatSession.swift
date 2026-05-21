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
    private let checkpointRepository: any CompactionCheckpointRepository
    private let llmProviderRegistry: LLMProviderRegistry
    private let toolRegistry: ToolRegistry
    private let contextAssembler: ContextAssembler
    private let compactor: Compactor
    private let clock: any Clock
    private let idGenerator: any IDGenerator

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

    /// User's configured system prompt, sourced from
    /// `ChatSettings.systemPrompt`. Injected as the leading `.system`
    /// LLMMessage on every turn by `ContextAssembler`. Mutated at runtime
    /// via `setSystemPrompt(_:)` so a Settings UI edit takes effect on
    /// the very next turn — including for long-running sessions the user
    /// returns to after editing.
    private var currentSystemPrompt: String

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
    ///   - systemPrompt: User's configured system prompt; injected by
    ///     `ContextAssembler` as the leading `.system` row on every turn.
    ///     Default `""` (no injection) so test fixtures and call sites
    ///     that don't carry settings keep working.
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
        systemPrompt: String = ""
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
        self.currentSystemPrompt = systemPrompt
    }

    /// Update the auto-compaction policy at runtime. M9's settings pane
    /// calls this when the user flips the toggle or moves the threshold
    /// slider so a long-running session picks up the new policy on its
    /// next turn.
    public func setAutoCompactPolicy(enabled: Bool, threshold: Double) {
        self.autoCompactEnabled = enabled
        self.autoCompactThreshold = threshold
    }

    /// Update the system prompt at runtime. The Settings UI calls this
    /// (via `ChatSessionStore.setSystemPrompt`) when the user edits the
    /// prompt so a long-running session picks up the new value on its
    /// next turn — current setting always wins over what the session was
    /// constructed with.
    public func setSystemPrompt(_ value: String) {
        self.currentSystemPrompt = value
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
            let persisted = try await self.messageRepository.fetchAll(conversationId: self.conversationId)
            guard persisted.contains(where: { $0.role == .user }) else { return }

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
        while true {
            try Task.checkCancellation()
            try await maybeAutoCompact(model: model)
            let history = try await assembleHistory(model: model)
            let enabledTools = await toolRegistry.enabledTools(for: provider)
            let toolCalls = try await streamOneTurn(
                provider: provider,
                messages: history,
                model: model,
                tools: enabledTools,
                temperature: temperature
            )
            if toolCalls.isEmpty { return }
            try await executeToolCalls(toolCalls)
        }
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
        return try await contextAssembler.assemble(
            messages: messages,
            toolCalls: toolCalls,
            checkpoint: checkpoint,
            model: model,
            systemPrompt: currentSystemPrompt
        )
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
    /// gate and owns the cancellation/error mapping so the public entry
    /// point can stay focused on stream wiring. Below the minimum context
    /// ratio the only event broadcast is `.error(.requestFailed(...))`;
    /// no LLM call, no checkpoint write.
    private func runCompaction(model: LLMModel) async {
        defer { currentTask = nil }
        do {
            let assembly = try await assemble(model: model)
            guard assembly.ratio >= manualCompactMinThreshold else {
                let pct = Int((manualCompactMinThreshold * 100).rounded())
                broadcast(.error(.requestFailed(
                    "Conversation is too short to compact yet — try again once context usage reaches \(pct)%."
                )))
                return
            }
            // Manual `/compact` summarizes everything up to now — no
            // trailing carve-out. The persisted checkpoint's
            // `uptoMessageId` becomes the last message on disk, so the
            // banner anchors at the bottom of the transcript and matches
            // the user's "I compacted everything" mental model.
            try await runCompactionPass(model: model, keepMostRecent: 0)
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
        // drops empty rows when projecting back).
        if accumulatedText.isEmpty && pendingCalls.isEmpty {
            return []
        }

        let thinkingDurationMs: Int? = {
            guard let start = thinkingStartedAt, let end = thinkingEndedAt else { return nil }
            return max(0, Int(end.timeIntervalSince(start) * 1000))
        }()
        let assistantMessage = MessageRecord(
            id: idGenerator.nextID(),
            conversationId: conversationId,
            role: .assistant,
            content: accumulatedText,
            thinkingContent: accumulatedThinking.isEmpty ? nil : accumulatedThinking,
            thinkingDurationMs: thinkingDurationMs,
            toolCallId: nil,
            createdAt: clock.now(),
            tokenCount: capturedUsage?.outputTokens
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
