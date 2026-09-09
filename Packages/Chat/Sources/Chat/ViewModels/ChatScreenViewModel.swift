import Core
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
public final class ChatScreenViewModel {
    public let conversationId: String

    public private(set) var items: [MessageList.Item] = []
    public private(set) var scrollRequest: MessageList.ScrollRequest?
    /// Partial output retained in memory after interruption; never a persisted row.
    public private(set) var interruptedResponse: MessageList.StreamingState?
    private var pendingScrollMessageID: String?
    private let clock: any Clock

    public private(set) var suggestions: [SuggestedChatAction] = []

    public private(set) var streamingTail: MessageList.StreamingState?

    public private(set) var error: MessageList.ErrorState?

    public var composerText: String = ""

    public private(set) var pendingReferences: [RecordReference] = []

    /// The selected configuration record ID, distinct from its upstream model ID.
    public var selectedModelId: String? {
        didSet {
            guard oldValue != selectedModelId, let id = selectedModelId else { return }
            onModelSelected?(id)
        }
    }

    /// Receives a configuration record ID, not the provider's model ID.
    public var onModelSelected: (@MainActor (String) -> Void)?

    public private(set) var verbosity: ChatVerbosity = .simple

    public private(set) var modelOptions: [ModelPill.Option]
    public private(set) var availableModels: [SelectableModel]

    /// Excludes the unpersisted streaming tail.
    public private(set) var usedTokens: Int = 0

    public private(set) var isStreaming: Bool = false

    public private(set) var showCopyConfirmation: Bool = false

    public private(set) var pendingRegenerationTargetID: String?

    public private(set) var pendingRegenerationDeleteCount: Int = 0

    public private(set) var headerTitle: String

    public let voice: VoiceInputController

    public private(set) var voiceState: VoiceInputController.State = .idle
    /// Provisional speech rendered separately from the append-only composer draft.
    public private(set) var voicePreview = ""
    private var voiceTask: Task<Void, Never>?
    private var lastVoiceRevision = 0
    private var voiceUpdateWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    /// Display-only projection. Recognition can revise the preview, never the draft.
    public var displayedComposerText: String {
        composerText + Self.voiceSuffix(voicePreview, after: composerText)
    }

    public var onTitleGenerated: (@MainActor (String) -> Void)?

    public var onAddModelRequested: (@MainActor @Sendable () -> Void)?

    private let driver: any ChatSessionDriver
    private let messageRepository: any MessageRepository
    private let toolCallRepository: any ToolCallRepository
    private let checkpointRepository: any CompactionCheckpointRepository
    private let conversationRepository: (any ConversationRepository)?
    private let titleGenerator: TitleGenerator?
    private let referenceInbox: ChatReferenceInbox?

    private let toolDisplayNames: [String: String]

    private let suggestionsProvider: any ChatSuggestionsProvider
    private let hapticsEngine: any HapticsEngine

    private var streamTask: Task<Void, Never>?
    private var titleTask: Task<Void, Never>?
    private var suggestionsTask: Task<Void, Never>?
    private var didRequestSuggestions = false
    /// Coalesces deltas so MarkdownUI does not reparse on every SSE event.
    private let streamingCoalescer: StreamingTextCoalescer
    private var cancelTask: Task<Void, Never>?
    /// Replaced on each copy so an older dismissal cannot hide a newer confirmation.
    private var copyDismissalTask: Task<Void, Never>?
    private let copyConfirmationSleep: @Sendable (Duration) async throws -> Void
    private var regenerationTask: Task<Void, Never>?
    /// Drops buffered events that can arrive after subscription cancellation.
    private var isDetached: Bool = false
    /// Prevents generated or user-owned titles from being replaced.
    private var hasGeneratedTitle: Bool = false
    /// Prevents later sends from replacing the initial fallback title.
    private var hasFallbackTitle: Bool = false

    public init(
        conversationId: String,
        conversationTitle: String,
        driver: any ChatSessionDriver,
        messageRepository: any MessageRepository,
        toolCallRepository: any ToolCallRepository,
        checkpointRepository: any CompactionCheckpointRepository,
        availableModels: [SelectableModel],
        selectedModelId: String? = nil,
        verbosity: ChatVerbosity = .simple,
        conversationRepository: (any ConversationRepository)? = nil,
        titleGenerator: TitleGenerator? = nil,
        voice: VoiceInputController? = nil,
        referenceInbox: ChatReferenceInbox? = nil,
        toolDisplayNames: [String: String] = [:],
        suggestionsProvider: any ChatSuggestionsProvider = StaticChatSuggestionsProvider(),
        hapticsEngine: any HapticsEngine = NoOpHapticsEngine(),
        clock: any Clock = SystemClock(),
        copyConfirmationSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
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
        self.toolDisplayNames = toolDisplayNames
        self.suggestionsProvider = suggestionsProvider
        self.hapticsEngine = hapticsEngine
        self.clock = clock
        self.copyConfirmationSleep = copyConfirmationSleep
        self.streamingCoalescer = StreamingTextCoalescer()
        self.availableModels = availableModels
        self.modelOptions = availableModels.map {
            ModelPill.Option(
                id: $0.recordId,
                displayName: $0.model.displayName,
                maxContextTokens: $0.model.maxContextTokens
            )
        }
        self.selectedModelId = selectedModelId ?? availableModels.first?.recordId
        self.verbosity = verbosity
        // Existing titles are user-owned and must not be regenerated on revisit.
        let alreadyTitled = !Self.titleNeedsGeneration(conversationTitle)
        self.hasGeneratedTitle = alreadyTitled
        self.hasFallbackTitle = alreadyTitled
        self.voice = voice ?? VoiceInputController(service: PlaceholderVoiceInputService())
        self.voiceState = self.voice.state
        // Register before capture; the weak owner permits dismissed chats to deallocate.
        let voiceUpdates = self.voice.updates()
        self.voiceTask = Task { [weak self] in
            for await update in voiceUpdates {
                guard let self, !Task.isCancelled else { return }
                self.consumeVoiceUpdate(update)
            }
        }
        self.streamingCoalescer.onFlush = { [weak self] chunk in
            self?.publishStreamingChunk(chunk)
        }
    }

    public var activeModel: LLMModel? {
        if let selectedModelId, let match = availableModels.first(where: { $0.recordId == selectedModelId }) {
            return match.model
        }
        return availableModels.first?.model
    }

    /// Accepts legacy persisted model IDs, but returns a configuration record ID.
    public static func resolveInitialModelId(
        persisted: String?,
        available: [SelectableModel]
    ) -> String? {
        if let match = available.first(where: { $0.recordId == persisted }) {
            return match.recordId
        }
        // Legacy fallback: an old persisted `LLMModel.id`.
        if let legacy = available.first(where: { $0.model.id == persisted }) {
            return legacy.recordId
        }
        return available.first?.recordId
    }

    public var maxContextTokens: Int {
        activeModel?.maxContextTokens ?? 0
    }

    public func load() async {
        interruptedResponse = nil
        await refreshTranscript()
        await attachToLiveTurnIfAny()
    }

    private func attachToLiveTurnIfAny() async {
        // Surface remounts must not add a second subscriber and duplicate streamed text.
        if isStreaming, streamTask != nil {
            return
        }
        let (snapshot, stream) = await driver.subscribe()
        guard let snapshot else { return }
        // Preserve elapsed-thinking time across detach and reattach.
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

    /// Generates empty-state suggestions at most once per view-model lifetime.
    public func loadSuggestionsIfNeeded(fallback: [SuggestedChatAction]) {
        // Set the once-only flag only when we actually proceed, so a call made
        // while the conversation already has messages doesn't permanently latch
        // it off (the empty-state branch is the only caller today, but the
        // ordering shouldn't depend on that).
        guard !didRequestSuggestions, items.isEmpty else { return }
        didRequestSuggestions = true
        suggestionsTask = Task { [weak self, suggestionsProvider] in
            let resolved = await suggestionsProvider.suggestions(fallback: fallback)
            guard let self, self.items.isEmpty else { return }
            self.suggestions = resolved
        }
    }

    func _setSnapshotState(
        items: [MessageList.Item],
        usedTokens: Int = 0,
        streamingTail: MessageList.StreamingState? = nil,
        error: MessageList.ErrorState? = nil,
        isStreaming: Bool = false
    ) {
        // ChatScreen relies on `streamingTail != nil` iff `isStreaming`.
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

    func _setSnapshotSuggestions(_ suggestions: [SuggestedChatAction]) {
        self.suggestions = suggestions
    }

    /// Drains fire-and-forget title work so parallel tests cannot outlive their fixtures.
    func _waitForPendingTitleTask() async {
        await titleTask?.value
    }

    /// Drains stream iteration for deterministic async tests.
    func _waitForPendingStreamTask() async {
        await streamTask?.value
    }

    func _waitForPendingCancelTask() async {
        await cancelTask?.value
    }

    func _waitForPendingCopyDismissalTask() async {
        await copyDismissalTask?.value
    }

    func _waitForPendingRegenerationTask() async {
        await regenerationTask?.value
    }

    func _waitForPendingSuggestionsTask() async {
        await suggestionsTask?.value
    }

    /// Slash-command text remains in the composer because it never becomes a user bubble.
    public func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming, !voiceState.isRecording, !voice.state.isRecording,
              lastVoiceRevision == voice.revision else { return }
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
        hapticsEngine.play(.selection)
        startStreaming(text: text, references: references, model: model)
    }

    /// Deduplicates reference IDs while draining the shell-owned inbox.
    public func adoptPendingReferences() {
        guard let referenceInbox else { return }
        var seenIDs = Set(pendingReferences.map(\.id))
        for reference in referenceInbox.drainPending() where seenIDs.insert(reference.id).inserted {
            pendingReferences.append(reference)
        }
    }

    public func removeReference(id: String) {
        pendingReferences.removeAll { $0.id == id }
    }

    public var inboxPendingCount: Int {
        referenceInbox?.pending.count ?? 0
    }

    /// Cancels the session task; ending only this subscription would leave generation running.
    public func cancelStreaming() {
        cancelTask = Task { [driver] in
            await driver.cancel()
        }
    }

    public func confirmSearch(id: String) {
        Task { [driver] in
            await driver.confirmToolCall(id: id)
        }
    }

    public func skipSearch(id: String) {
        Task { [driver] in
            await driver.skipToolCall(id: id)
        }
    }

    public func confirmCopy() {
        showCopyConfirmation = true
        // The transient, noninteractive pill otherwise has no VoiceOver focus.
        AccessibilityNotification.Announcement("Copied to clipboard").post()
        copyDismissalTask?.cancel()
        copyDismissalTask = Task { [weak self, copyConfirmationSleep] in
            do {
                try await copyConfirmationSleep(.seconds(1.2))
                self?.showCopyConfirmation = false
            } catch {}
        }
    }

    public func requestRegeneration(fromAssistantMessageID id: String) {
        guard !isStreaming else { return }
        // Trimming from a user row would leave an invalid provider history boundary.
        guard let targetIndex = items.firstIndex(where: { $0.id == id }),
              case .assistantText = items[targetIndex] else { return }
        let deletableCount = items[targetIndex...].reduce(into: 0) { acc, item in
            switch item {
            case .userBubble, .assistantText:
                acc += 1
            case .compactionBanner:
                break
            }
        }
        pendingRegenerationTargetID = id
        pendingRegenerationDeleteCount = deletableCount
    }

    public func cancelRegeneration() {
        pendingRegenerationTargetID = nil
        pendingRegenerationDeleteCount = 0
    }

    public func confirmRegeneration() {
        guard !isStreaming else { return }
        guard let targetID = pendingRegenerationTargetID else { return }
        pendingRegenerationTargetID = nil
        pendingRegenerationDeleteCount = 0
        regenerationTask = Task { [weak self] in
            await self?.performRegeneration(targetID: targetID)
        }
    }

    private func performRegeneration(targetID: String) async {
        do {
            let all = try await messageRepository.fetchAll(conversationId: conversationId)
            guard let targetIndex = all.firstIndex(where: { $0.id == targetID }) else { return }
            let trimmedIDs = all[targetIndex...].map(\.id)
            guard !trimmedIDs.isEmpty else { return }
            // Delete checkpoints first: a partial failure may resend surviving history,
            // but can never leave a checkpoint anchored to a deleted message.
            let trimmedIDSet = Set(trimmedIDs)
            let staleCheckpointIDs = try await checkpointRepository
                .all(for: conversationId)
                .filter { trimmedIDSet.contains($0.uptoMessageId) }
                .map(\.id)
            try await checkpointRepository.delete(ids: staleCheckpointIDs)
            try await messageRepository.delete(ids: trimmedIDs)
            await refreshTranscript()
            retry()
        } catch {
            self.error = MessageList.ErrorState(
                message: "Could not regenerate. Try again."
            )
        }
    }

    /// Leaves the actor-owned turn running while rejecting buffered events.
    public func detachFromLiveTurn() {
        isDetached = true
        // Release microphone ownership before the shell installs another composer.
        voice.stop()
        streamingCoalescer.reset()
        streamTask?.cancel()
    }

    public func handleMicTap() async {
        await voice.toggle()
    }

    public func handleStopRecording() {
        voice.stop()
    }

    private func consumeVoiceUpdate(_ update: VoiceInputUpdate) {
        if !update.appendedText.isEmpty {
            composerText.append(Self.voiceSuffix(update.appendedText, after: composerText))
        }
        voicePreview = update.preview
        voiceState = update.state
        handleVoiceStateChange(update.state)
        lastVoiceRevision = update.revision
        let ready = voiceUpdateWaiters.filter { $0.0 <= lastVoiceRevision }
        voiceUpdateWaiters.removeAll { $0.0 <= lastVoiceRevision }
        for (_, continuation) in ready { continuation.resume() }
    }

    private static func voiceSuffix(_ phrase: String, after draft: String) -> String {
        guard !phrase.isEmpty else { return "" }
        let separator = draft.last.map { $0.isWhitespace ? "" : " " } ?? ""
        return separator + phrase
    }

    /// Drains published voice updates for deterministic tests.
    func _waitForVoiceUpdates() async {
        await voice._waitForPendingStop()
        let revision = voice.revision
        guard lastVoiceRevision < revision else { return }
        await withCheckedContinuation { voiceUpdateWaiters.append((revision, $0)) }
    }

    isolated deinit {
        voice.stop()
        voiceTask?.cancel()
        for (_, continuation) in voiceUpdateWaiters { continuation.resume() }
    }

    /// Idle transitions preserve unrelated errors; voice failures suppress the LLM Retry action.
    public func handleVoiceStateChange(_ state: VoiceInputController.State) {
        switch state {
        case .denied:
            error = MessageList.ErrorState(
                message: "Voice input needs Speech Recognition and Microphone permissions. Open Settings to enable them.",
                actionLabel: "Settings",
                action: { Self.openSystemSettings() }
            )
        case .failed(let reason):
            error = MessageList.ErrorState(
                message: Self.voiceFailureMessage(for: reason),
                showsRetry: false
            )
        case .unavailable, .idle, .listening, .stopping:
            break
        }
    }

    /// `kLSRErrorDomain` commonly means unsupported Simulator dictation or disabled Dictation.
    private static func voiceFailureMessage(for reason: String) -> String {
        if reason.contains("kLSRErrorDomain") {
            return "Voice input doesn't work on the iOS Simulator — test on a real device, and ensure Dictation is enabled under Settings → General → Keyboard."
        }
        return "Voice input failed: \(reason)"
    }

    @MainActor
    private static func openSystemSettings() {
        #if canImport(UIKit) && os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }

    /// Falls back when selection disappears and clears a resolved no-model error.
    public func setAvailableModels(_ models: [SelectableModel]) {
        availableModels = models
        modelOptions = models.map {
            ModelPill.Option(
                id: $0.recordId,
                displayName: $0.model.displayName,
                maxContextTokens: $0.model.maxContextTokens
            )
        }
        if let current = selectedModelId,
           !models.contains(where: { $0.recordId == current }) {
            selectedModelId = models.first?.recordId
        } else if selectedModelId == nil {
            selectedModelId = models.first?.recordId
        }
        if !models.isEmpty, error?.kind == .noModelConfigured {
            error = nil
        }
    }

    public func applyExternalVerbosity(_ newValue: ChatVerbosity?) {
        guard let newValue else { return }
        verbosity = newValue
    }

    /// Retries the persisted user turn without inserting a duplicate user row.
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
        if let user = items.last(where: { if case .userBubble = $0 { return true }; return false }) {
            requestScroll(to: user.id)
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

    private func beginStream(_ make: @escaping @Sendable () async -> AsyncStream<ChatEvent>) {
        // Defensive: a prior turn that finished cleanly already drained
        // its buffer via the `consume` end-of-stream flush, but a turn
        // that was cancelled mid-burst could leave the timer scheduled.
        // Reset so a new turn never inherits a stale tail-piece.
        streamingCoalescer.reset()
        interruptedResponse = nil
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

    private func consume(stream: AsyncStream<ChatEvent>) async {
        for await event in stream {
            await handle(event)
        }
        if isDetached { return }
        // Drain buffered characters before clearing the tail at stream end.
        streamingCoalescer.flush()
        await refreshTranscript()
        if let tail = streamingTail, !tail.text.isEmpty || !tail.thinking.isEmpty {
            interruptedResponse = MessageList.StreamingState(
                thinking: tail.thinking,
                thinkingStartedAt: tail.thinkingStartedAt,
                thinkingDurationMs: tail.thinkingStartedAt.map { max(0, Int(clock.now().timeIntervalSince($0) * 1_000)) },
                text: tail.text,
                isCompacting: false
            )
        }
        streamingTail = nil
        isStreaming = false
        streamTask = nil
        hapticsEngine.play(.streamCompleted)
    }

    private func handle(_ event: ChatEvent) async {
        // AsyncStream may deliver already-buffered events after cancellation.
        if isDetached { return }
        switch event {
        case .userMessageSaved(let userMessage):
            pendingScrollMessageID = userMessage.id
            await refreshTranscript()
            await applyFallbackTitleIfNeeded(userText: userMessage.content)
        case .textDelta(let chunk):
            streamingCoalescer.append(chunk)
        case .thinkingDelta(let chunk):
            appendStreamingThinking(chunk)
        case .toolCallStarted, .toolCallCompleted, .toolCallFailed:
            await refreshTranscript()
        case .toolCallAwaitingConfirmation:
            await refreshTranscript()
            AccessibilityNotification.Announcement("Web search needs your approval").post()
        case .assistantMessageSaved(let assistantMessage):
            // Match the live tail to the persisted row before replacing it.
            streamingCoalescer.flush()
            // Keep live text visible until its persisted replacement is ready.
            await refreshTranscript(replacingStreamingTailWith: assistantMessage)
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
            // User cancellation is a clean stop and needs no error banner.
            if case .cancelled = llmError {
                error = nil
            } else {
                error = Self.errorState(for: llmError)
            }
        }
    }

    /// Never lets a late timer revive a torn-down streaming tail.
    private func publishStreamingChunk(_ chunk: String) {
        guard let current = streamingTail else { return }
        streamingTail = MessageList.StreamingState(
            thinking: current.thinking,
            thinkingStartedAt: current.thinkingStartedAt,
            text: current.text + chunk,
            isCompacting: current.isCompacting
        )
        hapticsEngine.play(.streamingTick)
    }

    private func appendStreamingThinking(_ chunk: String) {
        // A late thinking delta must not revive a detached streaming state.
        guard let current = streamingTail else { return }
        streamingTail = MessageList.StreamingState(
            thinking: current.thinking + chunk,
            thinkingStartedAt: current.thinkingStartedAt ?? clock.now(),
            text: current.text,
            isCompacting: current.isCompacting
        )
    }

    /// Writes a recognizable fallback while the generated title is pending or unavailable.
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

    nonisolated static func truncatedFallback(for userText: String, maxLength: Int = 20) -> String? {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= maxLength { return trimmed }
        let head = trimmed.prefix(maxLength).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else { return nil }
        return head + "…"
    }

    /// Runs once after the first text response; tool-only turns cannot supply title context.
    private func maybeGenerateTitle(from assistantMessage: MessageRecord) {
        // A generated title may replace the provisional truncation fallback.
        guard !hasGeneratedTitle,
              let titleGenerator,
              let conversationRepository else { return }
        let assistantText = assistantMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !assistantText.isEmpty else { return }
        guard let userText = lastPersistedUserText() else { return }

        // Mark before spawning so a fast tool loop cannot race a duplicate generation.
        hasGeneratedTitle = true
        let conversationId = self.conversationId

        titleTask = Task { [weak self] in
            let title = await titleGenerator.generate(
                userText: userText,
                assistantText: assistantText
            )
            guard let self else { return }
            guard let title else {
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
        } catch {}
        headerTitle = title
        onTitleGenerated?(title)
    }

    private func lastPersistedUserText() -> String? {
        for item in items.reversed() {
            if case .userBubble(_, let text, _) = item { return text }
        }
        return nil
    }

    nonisolated static func titleNeedsGeneration(_ title: String?) -> Bool {
        guard let title else { return true }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lowered = trimmed.lowercased()
        return lowered == "new chat"
    }

    private func requestScroll(to messageID: String) {
        scrollRequest = .init(messageID: messageID, sequence: (scrollRequest?.sequence ?? 0) + 1)
    }

    private func refreshTranscript(replacingStreamingTailWith savedAssistant: MessageRecord? = nil) async {
        do {
            let messages = try await messageRepository.fetchAll(conversationId: conversationId)
            let toolCalls = try await toolCallRepository.fetchByConversation(conversationId)
            let checkpoint = try await checkpointRepository.liveCheckpoint(for: conversationId)
            self.items = Self.project(
                messages: messages,
                toolCalls: toolCalls,
                checkpoint: checkpoint,
                toolDisplayNames: toolDisplayNames
            )
            if let messageID = pendingScrollMessageID,
               items.contains(where: { $0.id == messageID }) {
                requestScroll(to: messageID)
                pendingScrollMessageID = nil
            }
            self.usedTokens = messages.reduce(0) { $0 + ($1.tokenCount ?? 0) }
        } catch {
            self.error = MessageList.ErrorState(
                message: "Could not load messages: \(error.localizedDescription)"
            )
        }
        if let savedAssistant {
            // The event confirms this row was persisted even if a subsequent
            // read failed. Show that real row until a refresh supplies its tool
            // metadata, rather than duplicating it as an interrupted tail or
            // appending the next tool round's tokens to the completed response.
            if !items.contains(where: { $0.id == savedAssistant.id }) {
                items += Self.project(messages: [savedAssistant], toolCalls: [], checkpoint: nil)
            }
            streamingTail = .init(thinking: "", text: "", isCompacting: streamingTail?.isCompacting ?? false)
        }
    }

    /// Places the compaction banner after its inclusive cutoff, even when that
    /// row is hidden from the transcript or is the final persisted message.
    public nonisolated static func project(
        messages: [MessageRecord],
        toolCalls: [ToolCallRecord],
        checkpoint: CompactionCheckpointRecord?,
        toolDisplayNames: [String: String] = [:]
    ) -> [MessageList.Item] {
        var items: [MessageList.Item] = []
        let toolCallsByMessage = Dictionary(grouping: toolCalls, by: \.messageId)
        // Keyed by toolCallId. Tolerate duplicate ids (e.g. legacy chats where
        // a Gemini parallel call to the same tool persisted two results under
        // one id) — `uniqueKeysWithValues` would *trap* on a dup key and crash
        // the app on chat open. Projection of stored data must never trap; keep
        // the first result for a given id.
        let toolResults: [String: String] = Dictionary(
            messages.compactMap { message -> (String, String)? in
                guard let id = message.toolCallId else { return nil }
                return (id, message.content)
            },
            uniquingKeysWith: { first, _ in first }
        )

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
                        toolDisplayName: toolDisplayNames[call.toolName] ?? call.toolName,
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
                    toolCalls: calls,
                    sources: (message.attachments?.sources ?? []).map(Self.sourcePill),
                    searchSuggestionsHTML: message.attachments?.searchSuggestionsHTML,
                    searchSystem: message.attachments?.searchSystem,
                    searchQuery: message.attachments?.searchQuery
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

    /// Suppresses citation titles that merely repeat the display host.
    private nonisolated static func sourcePill(_ citation: SourceCitation) -> SourceCitationPillModel {
        let rawHost = citation.url.host() ?? ""
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        let displayHost = host.isEmpty ? citation.url.absoluteString : host
        let trimmedTitle = citation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Case-insensitive: a title like "Space.com" must still collapse
        // against host "space.com".
        let isRedundant = trimmedTitle.isEmpty
            || trimmedTitle.caseInsensitiveCompare(rawHost) == .orderedSame
            || trimmedTitle.caseInsensitiveCompare(host) == .orderedSame
        let title = isRedundant ? "" : trimmedTitle
        return SourceCitationPillModel(
            id: citation.id,
            title: title,
            host: displayHost,
            url: citation.url
        )
    }

    private nonisolated static func mapStatus(_ status: ToolCallStatus) -> MessageList.ToolCallItem.Status {
        switch status {
        case .pending, .executing:
            return .running
        case .awaitingConfirmation:
            return .awaitingConfirmation
        case .success:
            return .success
        case .failed, .cancelled:
            return .failed
        }
    }

    /// Keeps verbose provider bodies behind the banner's detail disclosure.
    private nonisolated static func errorState(for error: LLMError) -> MessageList.ErrorState {
        if case .providerError(let code, let message) = error {
            // `message` is "HTTP <code>" or "HTTP <code>: <body>". The summary
            // already states the status, so strip the redundant "HTTP <code>: "
            // prefix and surface just the provider body as the detail (nil when
            // there's no body beyond the status, so no empty disclosure).
            let prefix = "HTTP \(code): "
            let body = message.hasPrefix(prefix) ? String(message.dropFirst(prefix.count)) : message
            let hasBody = message != "HTTP \(code)"
            return MessageList.ErrorState(
                message: "The model provider returned an error (HTTP \(code)).",
                detail: hasBody ? body : nil
            )
        }
        return MessageList.ErrorState(message: describe(error))
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

public protocol ChatSessionDriver: Sendable {
    func send(text: String, model: LLMModel, references: [RecordReference]) async -> AsyncStream<ChatEvent>

    /// Re-runs the persisted turn without inserting another user message.
    func retry(model: LLMModel) async -> AsyncStream<ChatEvent>

    /// Returns a snapshot and event stream for the in-flight turn, or `nil` when idle.
    func subscribe() async -> (snapshot: ChatSession.LiveTurnSnapshot?, stream: AsyncStream<ChatEvent>)

    func cancel() async

    func confirmToolCall(id: String) async

    func skipToolCall(id: String) async
}

/// Reports availability to preserve fixture rendering, but denies capture if a host
/// fails to inject the production speech service.
private struct PlaceholderVoiceInputService: VoiceInputService {
    func stopRecognition() {}
    func isAvailable(locale: Locale) -> Bool { true }
    func requestPermissions() async -> VoiceInputPermissionStatus { .denied }
    func startRecognition(locale: Locale) -> AsyncThrowingStream<VoiceInputEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: VoiceInputError.unavailable)
        }
    }
}
