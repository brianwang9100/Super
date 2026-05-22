import Core
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// View model backing `ChatScreen`. Owns the composer's text buffer, the
/// resolved transcript items, the in-flight streaming buffers, and the
/// last error. SwiftUI re-renders via `@Observable`; the model itself is
/// `@MainActor` so all state mutations are serialized on the main actor
/// without needing locks.
///
/// `send(_:)` runs on the main actor, drives the underlying
/// `ChatSession.send(text:model:)` `AsyncStream<ChatEvent>`, and folds
/// each event back into observable state. Tests substitute a fake
/// `ChatSession` via `ChatSessionDriver`.
@MainActor
@Observable
public final class ChatScreenViewModel {
    public let conversationId: String

    /// Transcript items projected from persisted records. Re-resolved on
    /// every `userMessageSaved` / `assistantMessageSaved` /
    /// `compactionCompleted` event so the view sees post-write state.
    public private(set) var items: [MessageList.Item] = []

    /// Live streaming overlay (in-flight assistant text/thinking). nil
    /// when no turn is mid-flight.
    public private(set) var streamingTail: MessageList.StreamingState?

    /// Last terminal error from a turn. Cleared when the user retries or
    /// sends a new message.
    public private(set) var error: MessageList.ErrorState?

    /// Composer text. Two-way bound from the view.
    public var composerText: String = ""

    /// Verse-reference pills attached in the composer, pending send.
    /// Drained from the shell-owned `ChatReferenceInbox` via
    /// `adoptPendingReferences()` and folded into the outgoing message by
    /// `send(_:)`.
    public private(set) var pendingReferences: [RecordReference] = []

    /// Active model id selected in the model pill. Falls back to the
    /// first available model if nil. The didSet hook fires
    /// `onModelSelected` so the host can promote the matching provider
    /// to "active" in `LLMProviderRegistry` — without that wiring, the
    /// picker would be decorative (chat would always route to whatever
    /// provider was registered first).
    public var selectedModelId: String? {
        didSet {
            guard oldValue != selectedModelId, let id = selectedModelId else { return }
            onModelSelected?(id)
        }
    }

    /// Optional callback the host installs to promote a provider to
    /// active when the user picks a different model in the composer.
    /// Receives the picked `LLMModel.id` (the upstream "model identifier"
    /// like `claude-opus-4-7`, not the record UUID).
    public var onModelSelected: (@MainActor (String) -> Void)?

    /// Active verbosity used by `MessageList` to expand or collapse
    /// thinking and tool-call blocks. Mutated only through the init
    /// argument or `applyExternalVerbosity(_:)`.
    public private(set) var verbosity: ChatVerbosity = .simple

    public private(set) var modelOptions: [ModelPill.Option]
    public private(set) var availableModels: [LLMModel]

    /// Cumulative used tokens for the active conversation. Refreshed from
    /// the saved assistant rows; the streaming tail does not contribute
    /// until it persists.
    public private(set) var usedTokens: Int = 0

    /// `true` while a turn is in flight (composer disables submit, swaps
    /// the trailing button to a stop affordance).
    public private(set) var isStreaming: Bool = false

    /// True while the transient "Copied!" pill should be visible above the
    /// composer. Flipped on by `confirmCopy()` and auto-cleared by an
    /// internal dismissal `Task` after a short window.
    public private(set) var showCopyConfirmation: Bool = false

    /// ID of the assistant message the user tapped Regenerate on, or `nil`
    /// when no confirmation dialog is showing. `ChatScreen` binds the
    /// dialog's presentation to this being non-nil.
    public private(set) var pendingRegenerationTargetID: String?

    /// Count of transcript rows (target + everything after) that
    /// `confirmRegeneration()` will delete. Drives the dialog's wording
    /// — "Regenerate this response?" at 1, "… N later message(s) will be
    /// deleted." otherwise. Compaction banners are excluded from the
    /// count because they aren't deleted with the messages.
    public private(set) var pendingRegenerationDeleteCount: Int = 0

    /// Title shown in the chat header. Initialized from the persisted
    /// `ConversationRecord.title`; mutated when the auto-titler finishes
    /// summarizing the first exchange. Stored (not computed) so SwiftUI
    /// repaints the header through `@Observable` when the title lands.
    public private(set) var headerTitle: String

    /// Voice-input collaborator. Owns the active dictation session and
    /// publishes the partial transcript that the composer renders while
    /// recording. Wired in `init` so `onFinalTranscript` can splice
    /// committed text into `composerText` at session end.
    public let voice: VoiceInputController

    /// Snapshot of the user-typed composer prefix at the moment a
    /// recording session starts. Used by the view's composer binding to
    /// keep the typed prefix visible while the partial transcript
    /// streams in, and consumed by `onFinalTranscript` so the committed
    /// text appends to the prefix instead of replacing it.
    public private(set) var committedComposerText: String = ""

    /// Optional callback the host installs to react to a freshly
    /// generated title — typically `await sidebarViewModel.refresh()` so
    /// the sidebar's "New chat" placeholder flips to the real title.
    public var onTitleGenerated: (@MainActor (String) -> Void)?

    /// Optional callback the host installs to present the "Add Model"
    /// flow when the user taps the action button on the no-model error
    /// banner. The host typically deep-links the Settings sheet to
    /// `.modelDetail(id: nil)`. Kept separate from `onManageModels` (the
    /// composer's "Manage models…" entry) so the no-model fast path can
    /// land directly on the Add form instead of the Models list — there
    /// is by definition no list to browse in this state.
    public var onAddModelRequested: (@MainActor @Sendable () -> Void)?

    private let driver: any ChatSessionDriver
    private let messageRepository: any MessageRepository
    private let toolCallRepository: any ToolCallRepository
    private let checkpointRepository: any CompactionCheckpointRepository
    private let conversationRepository: (any ConversationRepository)?
    private let titleGenerator: TitleGenerator?
    /// Shell-owned inbox of cross-applet references awaiting a composer.
    /// Optional so previews, snapshot tests, and view-model unit tests
    /// without cross-applet wiring keep working.
    private let referenceInbox: ChatReferenceInbox?

    private var streamTask: Task<Void, Never>?
    private var titleTask: Task<Void, Never>?
    /// Decouples the per-SSE delta rate from the rate at which
    /// `streamingTail.text` repaints — `StreamingTail` renders MarkdownUI,
    /// so reparsing the AST on every delta would compound. Owned here
    /// because the view model owns the visible `streamingTail`. The
    /// callback is wired in `init` once all stored properties are set.
    private let streamingCoalescer: StreamingTextCoalescer
    /// The fire-and-forget cancel `Task` spawned by `cancelStreaming()`.
    /// Held only so tests can deterministically await it via
    /// `_waitForPendingCancelTask()` — production never reads it.
    private var cancelTask: Task<Void, Never>?
    /// The auto-dismissal `Task` for `showCopyConfirmation`. Cancelled on
    /// each fresh `confirmCopy()` so a rapid second copy resets the timer
    /// instead of letting the prior task race the new one.
    private var copyDismissalTask: Task<Void, Never>?
    /// The fire-and-forget regenerate `Task` spawned by
    /// `confirmRegeneration()`. Held so the test seam can await its
    /// completion deterministically.
    private var regenerationTask: Task<Void, Never>?
    /// Set once `detachFromLiveTurn()` has been called. Gates `handle(_:)`
    /// and `consume`'s final-cleanup writes so events already buffered in
    /// this view model's subscription (`AsyncStream` delivers them even
    /// after iteration is cancelled, until the iterator observes the
    /// cancel on its next call) cannot mutate observable state or kick
    /// off side effects like a title-generation LLM call for a chat the
    /// user has just navigated away from.
    private var isDetached: Bool = false
    /// Set after the first successful title-generation attempt so a
    /// subsequent `.assistantMessageSaved` doesn't rerun the LLM call. We
    /// don't reset this — once a chat has a generated title, the user
    /// owns it and renaming is manual.
    private var hasGeneratedTitle: Bool = false
    /// Set once the truncated-user-message fallback has been written, so
    /// a *second* user-send doesn't replace a (possibly-already-LLM-
    /// generated) title with a fresh truncation of the new prompt.
    private var hasFallbackTitle: Bool = false

    public init(
        conversationId: String,
        conversationTitle: String,
        driver: any ChatSessionDriver,
        messageRepository: any MessageRepository,
        toolCallRepository: any ToolCallRepository,
        checkpointRepository: any CompactionCheckpointRepository,
        availableModels: [LLMModel],
        selectedModelId: String? = nil,
        verbosity: ChatVerbosity = .simple,
        conversationRepository: (any ConversationRepository)? = nil,
        titleGenerator: TitleGenerator? = nil,
        voice: VoiceInputController? = nil,
        referenceInbox: ChatReferenceInbox? = nil
    ) {
        self.conversationId = conversationId
        self.headerTitle = conversationTitle
        self.driver = driver
        self.messageRepository = messageRepository
        self.toolCallRepository = toolCallRepository
        self.checkpointRepository = checkpointRepository
        self.conversationRepository = conversationRepository
        self.titleGenerator = titleGenerator
        self.referenceInbox = referenceInbox
        self.streamingCoalescer = StreamingTextCoalescer()
        self.availableModels = availableModels
        self.modelOptions = availableModels.map {
            ModelPill.Option(
                id: $0.id,
                displayName: $0.displayName,
                maxContextTokens: $0.maxContextTokens
            )
        }
        self.selectedModelId = selectedModelId ?? availableModels.first?.id
        self.verbosity = verbosity
        // A conversation that already has a real title (anything other
        // than the placeholder) is treated as already auto-titled so we
        // don't re-summarize on a return visit's first message; a real
        // title also implies the fallback step is no-op for the rest of
        // this view-model's lifetime.
        let alreadyTitled = !Self.titleNeedsGeneration(conversationTitle)
        self.hasGeneratedTitle = alreadyTitled
        self.hasFallbackTitle = alreadyTitled
        // Default to a controller backed by `PlaceholderVoiceInputService`
        // so callers that don't care about voice (snapshot tests,
        // previews, view-model unit tests) keep working without wiring a
        // fake. Production wires `SpeechRecognizerVoiceInputService` from
        // the composition root in `App/ContentView.swift`.
        self.voice = voice ?? VoiceInputController(service: PlaceholderVoiceInputService())
        // Capture the controller binding so the closure body can reach
        // committed text without a `self` strong-ref cycle.
        self.voice.onFinalTranscript = { [weak self] text in
            guard let self else { return }
            let prefix = self.committedComposerText
            if prefix.isEmpty {
                self.composerText = text
            } else if text.isEmpty {
                self.composerText = prefix
            } else {
                self.composerText = "\(prefix) \(text)"
            }
            self.committedComposerText = ""
        }
        // Wired after all stored props are set so the closure can
        // legally capture `self`. The coalescer publishes drained
        // chunks back into `streamingTail.text`.
        self.streamingCoalescer.onFlush = { [weak self] chunk in
            self?.publishStreamingChunk(chunk)
        }
    }

    public var activeModel: LLMModel? {
        if let selectedModelId, let match = availableModels.first(where: { $0.id == selectedModelId }) {
            return match
        }
        return availableModels.first
    }

    /// Resolves the initial `selectedModelId` for a new chat view model
    /// from a persisted "last selected" id and the currently-available
    /// model list. Returns the persisted id when it's still registered;
    /// otherwise falls back to the first available model (matching the
    /// stale-id-fallback branch in `setAvailableModels`). Returns nil when the
    /// list is empty.
    public static func resolveInitialModelId(
        persisted: String?,
        available: [LLMModel]
    ) -> String? {
        available.first(where: { $0.id == persisted })?.id ?? available.first?.id
    }

    public var maxContextTokens: Int {
        activeModel?.maxContextTokens ?? 0
    }

    /// Initial load of persisted messages + checkpoint. Called from
    /// `ChatScreen.task { await viewModel.load() }`. After refreshing the
    /// on-disk transcript, attaches to any turn the underlying session
    /// has in flight so a re-mounted screen picks up the live response
    /// from where it currently is — see `attachToLiveTurnIfAny()`.
    public func load() async {
        await refreshTranscript()
        await attachToLiveTurnIfAny()
    }

    /// If the underlying session is mid-turn, subscribe to its event
    /// feed and hydrate `streamingTail` from the snapshot so the user
    /// immediately sees the in-progress text/thinking. No-op when no turn
    /// is in flight — the returned stream finishes immediately.
    private func attachToLiveTurnIfAny() async {
        // Bail early if we're already consuming a live turn for this
        // view model. A `.task(id: viewModel.conversationId)` re-fire
        // (the chat surface remounting during a chat-presentation-state
        // transition like expanded → semi-expanded) would otherwise
        // call `driver.subscribe()` a second time, opening a parallel
        // `AsyncStream` over the same in-flight turn. Both subscribers
        // then append every text/thinking event to `streamingTail` and
        // the transcript, producing visible character duplication in
        // the live response.
        if isStreaming, streamTask != nil {
            return
        }
        let (snapshot, stream) = await driver.subscribe()
        guard let snapshot else { return }
        // `thinkingStartedAt` rides on the snapshot so the elapsed-time
        // label survives detach + re-attach. Without this the "Thought
        // for Xs" counter would visibly reset whenever a user navigated
        // away from a thinking chat and came back.
        streamingTail = MessageList.StreamingState(
            thinking: snapshot.accumulatedThinking,
            thinkingStartedAt: snapshot.thinkingStartedAt,
            text: snapshot.accumulatedText,
            isCompacting: false
        )
        isStreaming = true
        error = nil
        streamTask = Task { [weak self] in
            guard let self else { return }
            await self.consume(stream: stream)
        }
    }

    /// Inject pre-baked transcript state for snapshot tests and SwiftUI
    /// previews. Production callers should never invoke this — `load()`
    /// is the canonical entry point. The seam is internal so test targets
    /// (`@testable import Chat`) can prime the view model without
    /// widening the SDK contract.
    func _setSnapshotState(
        items: [MessageList.Item],
        usedTokens: Int = 0,
        streamingTail: MessageList.StreamingState? = nil,
        error: MessageList.ErrorState? = nil,
        isStreaming: Bool = false
    ) {
        // The view-model invariant — `streamingTail != nil ⇔ isStreaming
        // == true` — is what `ChatScreen`'s empty-state guard relies on
        // (it reads `isStreaming` to decide whether to show the greeting
        // vs. the transcript). Pin the pair here so a fixture that primes
        // a live tail without flipping `isStreaming` fails fast instead
        // of silently rendering the empty state during a streaming turn.
        precondition(
            (streamingTail != nil) == isStreaming,
            "streamingTail and isStreaming must agree; got tail=\(streamingTail != nil), isStreaming=\(isStreaming)"
        )
        self.items = items
        self.usedTokens = usedTokens
        self.streamingTail = streamingTail
        self.error = error
        self.isStreaming = isStreaming
    }

    /// Test seam: await the in-flight auto-title `Task` so a test can
    /// guarantee no background LLM call outlives the test body. Without
    /// this, the fire-and-forget `titleTask` can race the next test's
    /// scheduling under parallel execution and trip
    /// `FakeLLMProvider`'s strict empty-queue `fatalError`. Returns
    /// immediately when no title task is in flight.
    func _waitForPendingTitleTask() async {
        await titleTask?.value
    }

    /// Test seam: await the in-flight stream iteration `Task` so a test
    /// can deterministically synchronize on "this view model has
    /// finished draining its subscription" without polling
    /// `isStreaming`. Same rationale as `_waitForPendingTitleTask()` —
    /// see CLAUDE.md "Make async tests deterministic" for why polling
    /// loops are race amplifiers. Returns immediately when no stream
    /// task is in flight.
    func _waitForPendingStreamTask() async {
        await streamTask?.value
    }

    /// Test seam: await the fire-and-forget cancel `Task` spawned by
    /// `cancelStreaming()` so a test can deterministically assert the
    /// driver was actually invoked.
    func _waitForPendingCancelTask() async {
        await cancelTask?.value
    }

    /// Test seam: await the auto-dismissal `Task` for the copy
    /// confirmation pill so a test can synchronize on "the pill has
    /// finished its dwell" without polling `showCopyConfirmation`.
    func _waitForPendingCopyDismissalTask() async {
        await copyDismissalTask?.value
    }

    /// Test seam: await the in-flight regeneration `Task` so a test can
    /// synchronize on "the trim + retry have actually run" without
    /// polling `pendingRegenerationTargetID` or `isStreaming`.
    func _waitForPendingRegenerationTask() async {
        await regenerationTask?.value
    }

    /// Submit the current composer text. Silently no-ops when the text
    /// trims to empty or a turn is already in flight (both are routine
    /// user-driven states, not errors). When `activeModel` is `nil`
    /// (fresh build with zero configured model endpoints, since
    /// ``activeModel`` falls back to `availableModels.first`), surfaces
    /// a ``MessageList/ErrorState/noModelConfigured(onAddModel:)`` banner
    /// instead of dropping the tap on the floor — the user-typed text
    /// stays in the composer so they can resend after adding a model.
    ///
    /// Slash commands (e.g. `/compact`) also keep the composer text
    /// intact — unconditionally, not just on rejection. Two reasons:
    /// (1) a synchronous reject (manual `/compact` below the minimum
    /// context ratio) would otherwise vanish the user's typed command,
    /// forcing a re-type to retry; (2) even on success, a slash command
    /// is not written as a user bubble — leaving the text in place gives
    /// the user a consistent "your input persists until you clear it"
    /// model for command-style submissions. Regular (non-slash)
    /// submissions still clear immediately because the typed text gets
    /// rendered as its own user bubble below. If a future slash command
    /// has a different ergonomic, special-case it here.
    public func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming else { return }
        let isSlashCommand = SlashCommand(rawText: text) != nil
        // A slash command never becomes a user message, so it carries no
        // verse pills; a regular send consumes whatever is attached.
        let references = isSlashCommand ? [] : pendingReferences
        // A message may be pills-only — empty typed text is fine as long
        // as at least one verse is attached.
        guard !text.isEmpty || !references.isEmpty else { return }
        guard let model = activeModel else {
            error = .noModelConfigured { [weak self] in
                self?.onAddModelRequested?()
            }
            return
        }
        if !isSlashCommand {
            composerText = ""
            pendingReferences = []
        }
        error = nil
        startStreaming(text: text, references: references, model: model)
    }

    /// Drain the shell-owned `ChatReferenceInbox` into `pendingReferences`,
    /// deduping by reference id so a doubled bus delivery doesn't double a
    /// pill. Called by `ChatScreen` on mount and whenever the inbox grows.
    public func adoptPendingReferences() {
        guard let referenceInbox else { return }
        var seenIDs = Set(pendingReferences.map(\.id))
        // `insert(_:).inserted` dedupes against both the already-attached
        // pills and repeats within this drained batch.
        for reference in referenceInbox.drainPending() where seenIDs.insert(reference.id).inserted {
            pendingReferences.append(reference)
        }
    }

    /// Remove an attached verse pill (composer × button) before send.
    public func removeReference(id: String) {
        pendingReferences.removeAll { $0.id == id }
    }

    /// Count of references waiting in the shell-owned inbox. The view
    /// observes this — the inbox is `@Observable` — to know when to call
    /// `adoptPendingReferences()` for a verse added while already mounted.
    public var inboxPendingCount: Int {
        referenceInbox?.pending.count ?? 0
    }

    /// Cancel the in-flight turn (composer stop button). Routes through
    /// the driver so the underlying session's task is cancelled — not
    /// just this view model's iteration. Dropping the iteration alone
    /// would leave the LLM call running in the background, charging
    /// tokens for output the user can't see.
    public func cancelStreaming() {
        cancelTask = Task { [driver] in
            await driver.cancel()
        }
    }

    /// User tapped Copy on an assistant message: flip the pill state on
    /// and schedule its auto-dismissal. A fresh tap mid-dwell cancels the
    /// prior dismissal `Task` and restarts the timer — without the cancel
    /// the old task would fire after the new tap and clip the pill early.
    /// The pasteboard write itself stays at the call site so the
    /// `PasteboardClient` environment injection point doesn't move into
    /// the view model.
    public func confirmCopy() {
        showCopyConfirmation = true
        copyDismissalTask?.cancel()
        copyDismissalTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1.2))
                self?.showCopyConfirmation = false
            } catch {
                // Cancelled by a subsequent confirmCopy() — leave state unchanged.
            }
        }
    }

    /// User tapped Regenerate on an assistant message. Stages the
    /// confirmation dialog by recording the target id and how many
    /// transcript rows would be deleted on confirm — `ChatScreen` reads
    /// these to present a `.confirmationDialog` with copy adapted to the
    /// count. No-ops while a turn is mid-stream (matches the existing
    /// `send`/`retry` streaming guards) and when the target id isn't in
    /// the current items.
    public func requestRegeneration(fromAssistantMessageID id: String) {
        guard !isStreaming else { return }
        guard let targetIndex = items.firstIndex(where: { $0.id == id }) else { return }
        let deletableCount = items[targetIndex...].reduce(into: 0) { acc, item in
            switch item {
            case .userBubble, .assistantText:
                acc += 1
            case .compactionBanner:
                // Compaction banners project from `CompactionCheckpointRecord`,
                // not `MessageRecord`, so they aren't deleted by the trim
                // and shouldn't inflate the count shown to the user.
                break
            }
        }
        pendingRegenerationTargetID = id
        pendingRegenerationDeleteCount = deletableCount
    }

    /// User dismissed the regenerate confirmation dialog without
    /// confirming. Clears the pending state with no other side effects.
    public func cancelRegeneration() {
        pendingRegenerationTargetID = nil
        pendingRegenerationDeleteCount = 0
    }

    /// User confirmed the regenerate dialog. Spawns a background `Task`
    /// that trims the target assistant message and every persisted row
    /// after it, refreshes the transcript, then drives the existing
    /// `retry()` path. Tool-call rows cascade with their parent message
    /// via the `toolCall.messageId` foreign key, so deleting messages is
    /// sufficient. The pending dialog state clears synchronously so the
    /// dialog dismisses immediately.
    public func confirmRegeneration() {
        guard !isStreaming else { return }
        guard let targetID = pendingRegenerationTargetID else { return }
        pendingRegenerationTargetID = nil
        pendingRegenerationDeleteCount = 0
        regenerationTask = Task { [weak self] in
            await self?.performRegeneration(targetID: targetID)
        }
    }

    /// Trim → refresh → retry. Pulled into its own method so
    /// `confirmRegeneration()` can stay synchronous (clearing the dialog
    /// state in the same tick the button is tapped) while the async work
    /// runs in the spawned `Task`. Errors swallow silently for now —
    /// surfacing repo failures here would need a new banner state and
    /// the path is rare enough that crashing on it gives no signal.
    private func performRegeneration(targetID: String) async {
        do {
            let all = try await messageRepository.fetchAll(conversationId: conversationId)
            guard let targetIndex = all.firstIndex(where: { $0.id == targetID }) else { return }
            let trimmedIDs = all[targetIndex...].map(\.id)
            guard !trimmedIDs.isEmpty else { return }
            // Collect stale checkpoints — any `CompactionCheckpointRecord`
            // whose `uptoMessageId` anchor lands in the trim range. If
            // they survived, `ContextAssembler` would prepend a summary
            // covering messages that no longer exist.
            //
            // Delete order: checkpoints *first*, then messages. The two
            // writes can't be a single transaction without coupling the
            // two repos through a shared `DatabaseQueue` handle, so a
            // throw between them leaves the DB partially trimmed. With
            // this order, the failure mode of a thrown second delete is
            // "messages survived their anchored checkpoint" — `Context-
            // Assembler.messagesAfterCheckpoint`'s missing-anchor branch
            // doesn't apply (no checkpoint to apply it to) and the prior
            // turns get re-sent as normal history. The reverse order
            // would leave a checkpoint whose `uptoMessageId` points at a
            // deleted message, which is exactly the bug this cleanup is
            // meant to prevent.
            let trimmedIDSet = Set(trimmedIDs)
            let staleCheckpointIDs = try await checkpointRepository
                .all(for: conversationId)
                .filter { trimmedIDSet.contains($0.uptoMessageId) }
                .map(\.id)
            try await checkpointRepository.delete(ids: staleCheckpointIDs)
            try await messageRepository.delete(ids: trimmedIDs)
            await refreshTranscript()
            // `retry()` runs its own guards (no model, no user bubble,
            // already streaming) and is the canonical entry into the
            // LLM loop against the persisted transcript — calling it
            // keeps the streaming-tail/error-state plumbing consistent
            // with the error-banner Retry path.
            retry()
        } catch {
            // Surface the failure so the user knows the regenerate didn't
            // land — without this the dialog dismissed (synchronously in
            // `confirmRegeneration`) and the user saw no change, with no
            // signal that anything went wrong. The error banner offers
            // the same `Retry` affordance as the post-LLM-error path,
            // which then re-runs against whatever state survived.
            self.error = MessageList.ErrorState(
                message: "Could not regenerate. Try again."
            )
        }
    }

    /// Detach this view model from the in-flight turn without cancelling
    /// the underlying session. Called by the host when swapping this
    /// view model out (the user picked a different conversation). The
    /// stream iterator drops, the actor's subscriber list shrinks by
    /// one, and the turn keeps running for any other subscriber (or
    /// just to persist the final `MessageRecord`).
    ///
    /// Sets `isDetached = true` before cancelling so any event already
    /// buffered in this view model's subscription (delivered before the
    /// iterator observes the cancel) is dropped by `handle(_:)` rather
    /// than mutating observable state or firing background work.
    public func detachFromLiveTurn() {
        isDetached = true
        // Cancel the deferred flush so it doesn't wake into a torn-down
        // view model and re-emit characters into a tail that will never
        // be observed.
        streamingCoalescer.reset()
        streamTask?.cancel()
    }

    /// User tapped the composer mic. Freezes whatever they had already
    /// typed into `committedComposerText` so the partial transcript can
    /// stream in alongside the prefix without clobbering it, then asks
    /// the controller to start (or stop) the recognition session.
    public func handleMicTap() async {
        committedComposerText = composerText
        await voice.toggle()
    }

    /// User tapped the recording-stop affordance. Forwards to the
    /// controller, which commits the most recent partial transcript via
    /// the `onFinalTranscript` callback installed in `init`.
    public func handleStopRecording() {
        voice.stop()
    }

    /// Translate terminal voice-controller states into the existing
    /// error-banner surface. Wired from the screen via
    /// `.onChange(of: voice.state)`. `.unavailable` is reflected
    /// through the dimmed mic, not a banner; `.idle` and `.listening`
    /// don't touch the banner so an unrelated upstream error stays
    /// visible across a quick mic toggle.
    public func handleVoiceStateChange(_ state: VoiceInputController.State) {
        switch state {
        case .denied:
            error = MessageList.ErrorState(
                message: "Voice input needs Speech Recognition and Microphone permissions. Open Settings to enable them.",
                actionLabel: "Settings",
                action: { Self.openSystemSettings() }
            )
        case .failed(let reason):
            // Voice failures aren't retryable through the parent's
            // `onRetry` (that re-sends the last LLM message, not the
            // voice attempt). Suppress the Retry pill so the banner
            // can't trigger an unrelated resend; the user dismisses by
            // sending a message or tapping the mic again.
            error = MessageList.ErrorState(
                message: Self.voiceFailureMessage(for: reason),
                showsRetry: false
            )
        case .unavailable, .idle, .listening:
            break
        }
    }

    /// Translate the raw voice-controller failure reason into a banner
    /// message the user can act on. The recognizer surfaces
    /// `kLSRErrorDomain` (Local Speech Recognition) errors when the
    /// on-device dictation model isn't available — e.g. on the iOS
    /// simulator (officially unsupported on iOS 17+) or when the user
    /// has dictation switched off. Surface a hint that names both root
    /// causes rather than echoing the raw domain code.
    private static func voiceFailureMessage(for reason: String) -> String {
        if reason.contains("kLSRErrorDomain") {
            return "Voice input doesn't work on the iOS Simulator — test on a real device, and ensure Dictation is enabled under Settings → General → Keyboard."
        }
        return "Voice input failed: \(reason)"
    }

    /// Open the iOS Settings app at the Super entry. Routed through a
    /// nonisolated `@MainActor`-safe helper so the banner closure can
    /// stay `Sendable`.
    @MainActor
    private static func openSystemSettings() {
        #if canImport(UIKit) && os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }

    /// Replace the picker's model list. Called by the host when
    /// `SettingsViewModel.onModelsChanged` fires so newly added or
    /// renamed models appear in the composer without an app restart. If
    /// the previously selected id disappears, falls back to the first
    /// available model.
    ///
    /// Also clears a `noModelConfigured` error banner the moment any
    /// model becomes available — the underlying condition is resolved,
    /// so the banner shouldn't linger. Unrelated `generic` errors are
    /// left untouched.
    public func setAvailableModels(_ models: [LLMModel]) {
        availableModels = models
        modelOptions = models.map {
            ModelPill.Option(
                id: $0.id,
                displayName: $0.displayName,
                maxContextTokens: $0.maxContextTokens
            )
        }
        if let current = selectedModelId,
           !models.contains(where: { $0.id == current }) {
            selectedModelId = models.first?.id
        } else if selectedModelId == nil {
            selectedModelId = models.first?.id
        }
        if !models.isEmpty, error?.kind == .noModelConfigured {
            error = nil
        }
    }

    /// Apply a new verbosity from an external source. `nil` is a no-op
    /// so an optional-binding observable (`ChatVerbosity?`) can pass
    /// straight through during the bootstrap window without an extra
    /// guard at the call site.
    public func applyExternalVerbosity(_ newValue: ChatVerbosity?) {
        guard let newValue else { return }
        verbosity = newValue
    }

    /// Retry after an error: re-run the LLM loop against the
    /// already-persisted transcript. The failed user `MessageRecord` is
    /// still on disk from the failed turn, so retry must not write a
    /// second one — that's why this calls `driver.retry(...)` instead of
    /// the normal `send(...)` path. If no model is active, just clear
    /// the error. Mirrors `send`'s `!isStreaming` guard so a double-tap
    /// while a turn is already in flight cannot spawn a second `consume`
    /// task racing the first over the same observable state.
    ///
    /// Synchronously checks `items` for a user bubble before touching
    /// any streaming flags — if there's nothing to retry (brand-new
    /// conversation, transcript wiped) we want to no-op without flashing
    /// the streaming UI on and back off. `ChatSession.runRetry` has the
    /// same guard against the persisted transcript as defense-in-depth.
    public func retry() {
        guard !isStreaming else { return }
        guard let model = activeModel else {
            error = nil
            return
        }
        let hasUserBubble = items.contains(where: {
            if case .userBubble = $0 { return true }
            return false
        })
        guard hasUserBubble else {
            error = nil
            return
        }
        error = nil
        beginStream { [driver] in
            await driver.retry(model: model)
        }
    }

    private func startStreaming(text: String, references: [RecordReference], model: LLMModel) {
        beginStream { [driver] in
            await driver.send(text: text, model: model, references: references)
        }
    }

    /// Shared scaffold for kicking off a streaming turn: flip the
    /// observable streaming flags, install a fresh `streamingTail`, and
    /// spawn the `consume(stream:)` task on `streamTask`. Callers supply
    /// the closure that produces the event stream (`send` vs `retry`).
    private func beginStream(_ make: @escaping @Sendable () async -> AsyncStream<ChatEvent>) {
        // Defensive: a prior turn that finished cleanly already drained
        // its buffer via the `consume` end-of-stream flush, but a turn
        // that was cancelled mid-burst could leave the timer scheduled.
        // Reset so a new turn never inherits a stale tail-piece.
        streamingCoalescer.reset()
        isStreaming = true
        streamingTail = MessageList.StreamingState(
            thinking: "",
            thinkingStartedAt: nil,
            text: "",
            isCompacting: false
        )
        streamTask = Task { [weak self] in
            guard let self else { return }
            let stream = await make()
            await self.consume(stream: stream)
        }
    }

    /// Iterate a session event stream — used by both the initial `send`
    /// path and the re-attach path in `attachToLiveTurnIfAny`. Drains
    /// every event through `handle(_:)`, then refreshes the transcript
    /// one last time and clears the streaming UI. Skips the final
    /// cleanup if `detachFromLiveTurn()` was called — at that point the
    /// host has already replaced this view model, so its observable
    /// state and any GRDB round-trip would be wasted.
    private func consume(stream: AsyncStream<ChatEvent>) async {
        for await event in stream {
            await handle(event)
        }
        if isDetached { return }
        // Stream-end may arrive with characters still in the coalescer
        // buffer (cancel, error, or a turn that finished without a
        // closing whitespace). Drain before tearing down the overlay so
        // a later timer fire can't write into a nil `streamingTail`.
        streamingCoalescer.flush()
        await refreshTranscript()
        streamingTail = nil
        isStreaming = false
        streamTask = nil
    }

    private func handle(_ event: ChatEvent) async {
        // Drop any event delivered after the host detached this view
        // model. `AsyncStream` can return events already in its buffer
        // even after the iteration task is cancelled, so without this
        // gate a detached view model could still mutate observable
        // state, refresh from GRDB, or — most expensively — fire a
        // title-generation LLM call on the user's behalf for a chat
        // they've already navigated away from.
        if isDetached { return }
        switch event {
        case .userMessageSaved(let userMessage):
            await refreshTranscript()
            await applyFallbackTitleIfNeeded(userText: userMessage.content)
        case .textDelta(let chunk):
            streamingCoalescer.append(chunk)
        case .thinkingDelta(let chunk):
            appendStreamingThinking(chunk)
        case .toolCallStarted, .toolCallCompleted, .toolCallFailed:
            await refreshTranscript()
        case .assistantMessageSaved(let assistantMessage):
            // Drain any buffered coalescer characters into the visible
            // tail before clearing — keeps the overlay byte-for-byte
            // identical to what the persisted assistant row will render
            // a moment later through `refreshTranscript()`.
            streamingCoalescer.flush()
            // Clear the streaming text now that the canonical row exists.
            streamingTail = MessageList.StreamingState(
                thinking: "",
                thinkingStartedAt: nil,
                text: "",
                isCompacting: streamingTail?.isCompacting ?? false
            )
            await refreshTranscript()
            maybeGenerateTitle(from: assistantMessage)
        case .compactionStarted:
            streamingTail = MessageList.StreamingState(
                thinking: streamingTail?.thinking ?? "",
                thinkingStartedAt: streamingTail?.thinkingStartedAt,
                text: streamingTail?.text ?? "",
                isCompacting: true
            )
        case .compactionCompleted:
            streamingTail = MessageList.StreamingState(
                thinking: streamingTail?.thinking ?? "",
                thinkingStartedAt: streamingTail?.thinkingStartedAt,
                text: streamingTail?.text ?? "",
                isCompacting: false
            )
            await refreshTranscript()
        case .error(let llmError):
            // `.cancelled` is only ever surfaced when the user taps the
            // stop affordance — that's a clean stop, not a failure, so
            // suppress the banner. Other errors get the human-readable
            // banner copy.
            if case .cancelled = llmError {
                error = nil
            } else {
                error = MessageList.ErrorState(message: Self.describe(llmError))
            }
        }
    }

    /// Coalescer callback: append a drained chunk to the visible tail.
    /// Discards silently if the tail has already been torn down — a
    /// timer that fires just after `streamingTail = nil` would
    /// otherwise revive a stale overlay.
    private func publishStreamingChunk(_ chunk: String) {
        guard let current = streamingTail else { return }
        streamingTail = MessageList.StreamingState(
            thinking: current.thinking,
            thinkingStartedAt: current.thinkingStartedAt,
            text: current.text + chunk,
            isCompacting: current.isCompacting
        )
    }

    private func appendStreamingThinking(_ chunk: String) {
        // Discard rather than revive — symmetric with
        // `publishStreamingChunk`. A `.thinkingDelta` that arrives
        // after the overlay was torn down (a late event surfaced as
        // `consume` exited) must not re-create a streaming state, or
        // the empty-state guard in `ChatScreen` would silently re-show
        // the overlay against the now-persisted assistant row.
        guard let current = streamingTail else { return }
        streamingTail = MessageList.StreamingState(
            thinking: current.thinking + chunk,
            thinkingStartedAt: current.thinkingStartedAt ?? Date(),
            text: current.text,
            isCompacting: current.isCompacting
        )
    }

    /// Stamp a truncated-user-message fallback title the moment the
    /// user's first message persists, so the header and sidebar carry
    /// *something* recognizable while the LLM-backed summarizer is still
    /// running (or in case it errors out and never produces one). The
    /// LLM-generated title overwrites this when it lands; if the LLM
    /// path never succeeds, the truncation is the final title.
    ///
    /// Skipped when a repository wasn't injected, when the LLM-titler has
    /// already committed (so a successful auto-title doesn't get reverted
    /// by a *second* user message), or when the conversation already has
    /// a real (non-placeholder) title.
    private func applyFallbackTitleIfNeeded(userText: String) async {
        guard !hasGeneratedTitle,
              !hasFallbackTitle,
              let conversationRepository,
              Self.titleNeedsGeneration(headerTitle) else { return }
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fallback = Self.truncatedFallback(for: trimmed) else { return }
        hasFallbackTitle = true
        await applyGeneratedTitle(
            fallback,
            conversationId: conversationId,
            repository: conversationRepository
        )
    }

    /// Truncate to `maxLength` characters with a trailing ellipsis when
    /// trimming actually shortens the string. Returns `nil` for an empty
    /// or whitespace-only message so the caller can leave the placeholder
    /// alone.
    nonisolated static func truncatedFallback(for userText: String, maxLength: Int = 20) -> String? {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= maxLength { return trimmed }
        let head = trimmed.prefix(maxLength).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else { return nil }
        return head + "…"
    }

    /// Kick off the auto-title call after the first usable assistant
    /// message lands. Skipped when a generator/repository wasn't injected
    /// (snapshot tests, previews), when the title is already set by the
    /// user, when this view-model instance has already fired generation,
    /// when the assistant message has no text yet (tool-only turn), or
    /// when no model is active. Runs detached so the composer re-enables
    /// without waiting on the title round-trip.
    private func maybeGenerateTitle(from assistantMessage: MessageRecord) {
        // We gate solely on `hasGeneratedTitle` (set true at init when
        // the conversation already had a real title, or after a
        // successful generation). The current `headerTitle` may be the
        // truncation fallback we wrote on user-send, which we *do* want
        // the LLM-generated title to overwrite.
        guard !hasGeneratedTitle,
              let titleGenerator,
              let conversationRepository,
              let model = activeModel else { return }
        let assistantText = assistantMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !assistantText.isEmpty else { return }
        guard let userText = lastPersistedUserText() else { return }

        // Mark synchronously so a rapid second `.assistantMessageSaved`
        // (e.g. a tool-loop turn that completes shortly after) doesn't
        // race a duplicate generation before the first task writes the
        // row.
        hasGeneratedTitle = true
        let conversationId = self.conversationId

        titleTask = Task { [weak self] in
            let title = await titleGenerator.generate(
                userText: userText,
                assistantText: assistantText,
                model: model
            )
            guard let self else { return }
            guard let title else {
                // Generation failed or returned empty — clear the flag
                // so a future first message retries and a one-off network
                // blip doesn't permanently leave the chat as "New chat".
                self.hasGeneratedTitle = false
                return
            }
            await self.applyGeneratedTitle(
                title,
                conversationId: conversationId,
                repository: conversationRepository
            )
        }
    }

    private func applyGeneratedTitle(
        _ title: String,
        conversationId: String,
        repository: any ConversationRepository
    ) async {
        do {
            guard var record = try await repository.fetch(id: conversationId) else { return }
            record.title = title
            record.updatedAt = Date()
            try await repository.save(record)
        } catch {
            // Title write failed; keep the in-memory header update so the
            // user sees something rather than silently doing nothing, and
            // let the next launch reseed from the (still-placeholder) DB
            // row.
        }
        headerTitle = title
        onTitleGenerated?(title)
    }

    /// Returns the most recent persisted user-bubble text from the
    /// projected items. Used to feed the title generator with the user's
    /// half of the first exchange.
    private func lastPersistedUserText() -> String? {
        for item in items.reversed() {
            if case .userBubble(_, let text, _) = item { return text }
        }
        return nil
    }

    /// Whether a stored title looks like the placeholder (so the
    /// auto-titler should overwrite it). Treats nil, empty, and the two
    /// known placeholders ("New chat", "New Chat") as needing generation.
    /// Anything else is considered user-owned and left alone.
    nonisolated static func titleNeedsGeneration(_ title: String?) -> Bool {
        guard let title else { return true }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lowered = trimmed.lowercased()
        return lowered == "new chat"
    }

    private func refreshTranscript() async {
        do {
            let messages = try await messageRepository.fetchAll(conversationId: conversationId)
            let toolCalls = try await toolCallRepository.fetchByConversation(conversationId)
            let checkpoint = try await checkpointRepository.liveCheckpoint(for: conversationId)
            self.items = Self.project(
                messages: messages,
                toolCalls: toolCalls,
                checkpoint: checkpoint
            )
            self.usedTokens = messages.reduce(0) { $0 + ($1.tokenCount ?? 0) }
        } catch {
            self.error = MessageList.ErrorState(
                message: "Could not load messages: \(error.localizedDescription)"
            )
        }
    }

    /// Project on-disk records into `MessageList.Item`s. Pure
    /// (`nonisolated`) so callers in any context — snapshot tests,
    /// previews, future async pipelines — can run it directly without an
    /// actor hop.
    ///
    /// Compaction banner placement: walk `messages` in order; once we
    /// pass the message whose id matches `checkpoint.uptoMessageId` (the
    /// inclusive cutoff from `ContextAssembler`) we *arm* the banner and
    /// emit it before the next renderable row. If the cutoff is also the
    /// last persisted message, we emit it at the tail. This handles the
    /// cases the previous "compare to last item" heuristic missed —
    /// notably when the cutoff lands on a `.system` or `.tool` row that
    /// the projection drops, or when the cutoff is the final message.
    public nonisolated static func project(
        messages: [MessageRecord],
        toolCalls: [ToolCallRecord],
        checkpoint: CompactionCheckpointRecord?
    ) -> [MessageList.Item] {
        var items: [MessageList.Item] = []
        let toolCallsByMessage = Dictionary(grouping: toolCalls, by: \.messageId)
        let toolResults: [String: String] = Dictionary(uniqueKeysWithValues: messages.compactMap {
            guard let id = $0.toolCallId else { return nil }
            return (id, $0.content)
        })

        var bannerArmed = false
        var bannerEmitted = false

        func emitBannerIfArmed() {
            guard let cp = checkpoint, bannerArmed, !bannerEmitted else { return }
            items.append(.compactionBanner(id: "banner-\(cp.id)", summary: cp.summary))
            bannerEmitted = true
        }

        for message in messages {
            emitBannerIfArmed()

            switch message.role {
            case .user:
                items.append(.userBubble(
                    id: message.id,
                    text: message.content,
                    references: (message.attachments?.references ?? []).map {
                        VerseReferencePillModel(id: $0.id, label: $0.displayLabel)
                    }
                ))
            case .assistant:
                let calls = (toolCallsByMessage[message.id] ?? []).map { call in
                    MessageList.ToolCallItem(
                        id: call.id,
                        toolName: call.toolName,
                        parametersJSON: call.parameters,
                        resultText: toolResults[call.id],
                        status: Self.mapStatus(call.status)
                    )
                }
                items.append(.assistantText(
                    id: message.id,
                    thinking: message.thinkingContent,
                    thinkingDurationMs: message.thinkingDurationMs,
                    text: message.content,
                    toolCalls: calls
                ))
            case .system:
                // System rows are not rendered in the transcript today —
                // they live in the prompt assembly but never on screen.
                break
            case .tool:
                // Tool result rows are folded into the parent assistant's
                // tool-call block via `toolResults` above.
                break
            }

            if let cp = checkpoint, message.id == cp.uptoMessageId {
                bannerArmed = true
            }
        }

        // Cutoff was the last persisted message — emit the banner at the
        // tail so the user still sees that compaction happened.
        emitBannerIfArmed()
        return items
    }

    private nonisolated static func mapStatus(_ status: ToolCallStatus) -> MessageList.ToolCallItem.Status {
        switch status {
        case .pending, .executing, .awaitingConfirmation:
            return .running
        case .success:
            return .success
        case .failed, .cancelled:
            return .failed
        }
    }

    private nonisolated static func describe(_ error: LLMError) -> String {
        switch error {
        case .unauthorized:
            return "Authentication failed. Check the API key in Settings."
        case .rateLimited:
            return "Rate limited by the model provider. Try again shortly."
        case .cancelled:
            return "Stopped."
        case .requestFailed(let message),
             .providerError(_, let message),
             .decodingFailed(let message),
             .unsupportedModel(let message):
            return message
        }
    }
}

/// Indirection between `ChatScreenViewModel` and `ChatSession` so the view
/// model can be tested with a fake driver without spinning up GRDB or an
/// LLM provider. The production conformer lives in
/// `ChatSessionDriver+Adapter.swift`.
public protocol ChatSessionDriver: Sendable {
    /// Submit a user turn. `references` carries any verse-reference pills
    /// attached in the composer; the underlying session persists them on
    /// the user `MessageRecord` and `ContextAssembler` expands them into
    /// the prompt.
    func send(text: String, model: LLMModel, references: [RecordReference]) async -> AsyncStream<ChatEvent>

    /// Re-run the LLM turn loop against the already-persisted transcript.
    /// Used by the error banner's Retry pill: the failed user message is
    /// already on disk, so retry must not write a second one. No
    /// `references` parameter — retry never carries new pills.
    func retry(model: LLMModel) async -> AsyncStream<ChatEvent>

    /// Attach to the underlying session's in-flight turn (if any). The
    /// view model calls this on `load()` so a re-mounted screen for a
    /// conversation whose session is mid-turn picks up where it left off
    /// instead of waiting for `.assistantMessageSaved` to repaint from
    /// GRDB. The snapshot is `nil` (and the stream finishes immediately)
    /// when no turn is in flight.
    func subscribe() async -> (snapshot: ChatSession.LiveTurnSnapshot?, stream: AsyncStream<ChatEvent>)

    /// Cancel the session's current turn. The composer's stop button
    /// calls this — dropping the view model's iteration alone no longer
    /// cancels the underlying work (so view-model swaps don't abort
    /// streams), so an explicit cancel hook is needed.
    func cancel() async
}

/// Default ``VoiceInputService`` used when no controller is injected
/// into ``ChatScreenViewModel``. Deliberately *lies* about availability
/// (returns `true`) so snapshot tests + previews render the live mic icon
/// at idle without breaking the pre-M11 baseline, then deflects a real
/// tap by returning `.denied` from `requestPermissions()` so the user
/// sees the permission banner instead of a silent no-op. Production hosts
/// must replace this with `SpeechRecognizerVoiceInputService` —
/// "Placeholder" (not "Noop") in the name to keep that lie visible at
/// every reference site.
private struct PlaceholderVoiceInputService: VoiceInputService {
    func isAvailable(locale: Locale) -> Bool { true }
    func requestPermissions() async -> VoiceInputPermissionStatus { .denied }
    func startRecognition(locale: Locale) -> AsyncThrowingStream<VoiceInputEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: VoiceInputError.unavailable)
        }
    }
}
