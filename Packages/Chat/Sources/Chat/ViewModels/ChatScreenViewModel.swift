import Core
import Foundation
import SwiftUI

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
    public private(set) var items: [MessageListView.Item] = []

    /// Live streaming overlay (in-flight assistant text/thinking). nil
    /// when no turn is mid-flight.
    public private(set) var streamingTail: MessageListView.StreamingTail?

    /// Last terminal error from a turn. Cleared when the user retries or
    /// sends a new message.
    public private(set) var error: MessageListView.ErrorBanner?

    /// Composer text. Two-way bound from the view.
    public var composerText: String = ""

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

    /// Active verbosity selected in the verbosity pill.
    public var verbosity: ChatVerbosity = .simple

    public private(set) var modelOptions: [ModelPill.Option]
    public private(set) var availableModels: [LLMModel]

    /// Cumulative used tokens for the active conversation. Refreshed from
    /// the saved assistant rows; the streaming tail does not contribute
    /// until it persists.
    public private(set) var usedTokens: Int = 0

    /// `true` while a turn is in flight (composer disables submit, swaps
    /// the trailing button to a stop affordance).
    public private(set) var isStreaming: Bool = false

    /// Title shown in the chat header. Initialized from the persisted
    /// `ConversationRecord.title`; mutated when the auto-titler finishes
    /// summarizing the first exchange. Stored (not computed) so SwiftUI
    /// repaints the header through `@Observable` when the title lands.
    public private(set) var headerTitle: String

    /// Optional callback the host installs to react to a freshly
    /// generated title — typically `await sidebarViewModel.refresh()` so
    /// the sidebar's "New chat" placeholder flips to the real title.
    public var onTitleGenerated: (@MainActor (String) -> Void)?

    private let driver: any ChatSessionDriver
    private let messageRepository: any MessageRepository
    private let toolCallRepository: any ToolCallRepository
    private let checkpointRepository: any CompactionCheckpointRepository
    private let conversationRepository: (any ConversationRepository)?
    private let titleGenerator: TitleGenerator?

    private var streamTask: Task<Void, Never>?
    private var titleTask: Task<Void, Never>?
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
        titleGenerator: TitleGenerator? = nil
    ) {
        self.conversationId = conversationId
        self.headerTitle = conversationTitle
        self.driver = driver
        self.messageRepository = messageRepository
        self.toolCallRepository = toolCallRepository
        self.checkpointRepository = checkpointRepository
        self.conversationRepository = conversationRepository
        self.titleGenerator = titleGenerator
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
    }

    public var activeModel: LLMModel? {
        if let selectedModelId, let match = availableModels.first(where: { $0.id == selectedModelId }) {
            return match
        }
        return availableModels.first
    }

    public var maxContextTokens: Int {
        activeModel?.maxContextTokens ?? 0
    }

    /// Initial load of persisted messages + checkpoint. Called from
    /// `ChatScreen.task { await viewModel.load() }`.
    public func load() async {
        await refreshTranscript()
    }

    /// Inject pre-baked transcript state for snapshot tests and SwiftUI
    /// previews. Production callers should never invoke this — `load()`
    /// is the canonical entry point. The seam is internal so test targets
    /// (`@testable import Chat`) can prime the view model without
    /// widening the SDK contract.
    func _setSnapshotState(
        items: [MessageListView.Item],
        usedTokens: Int = 0,
        streamingTail: MessageListView.StreamingTail? = nil,
        error: MessageListView.ErrorBanner? = nil,
        isStreaming: Bool = false
    ) {
        self.items = items
        self.usedTokens = usedTokens
        self.streamingTail = streamingTail
        self.error = error
        self.isStreaming = isStreaming
    }

    /// Submit the current composer text. No-op when empty or when a turn
    /// is already in flight.
    public func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming, let model = activeModel else { return }
        composerText = ""
        error = nil
        startStreaming(text: text, model: model)
    }

    /// Cancel the in-flight turn, if any.
    public func cancelStreaming() {
        streamTask?.cancel()
    }

    /// Replace the picker's model list. Called by the host when
    /// `SettingsViewModel.onModelsChanged` fires so newly added or
    /// renamed models appear in the composer without an app restart. If
    /// the previously selected id disappears, falls back to the first
    /// available model.
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
    }

    /// Retry after an error: re-send the most recent user message. If we
    /// can't find one, just clear the error.
    public func retry() {
        guard let lastUser = items.reversed().first(where: {
            if case .userBubble = $0 { return true }
            return false
        }), case .userBubble(_, let text) = lastUser, let model = activeModel else {
            error = nil
            return
        }
        error = nil
        startStreaming(text: text, model: model)
    }

    private func startStreaming(text: String, model: LLMModel) {
        isStreaming = true
        streamingTail = MessageListView.StreamingTail(
            thinking: "",
            thinkingStartedAt: nil,
            text: "",
            isCompacting: false
        )
        streamTask = Task { [weak self] in
            guard let self else { return }
            await self.run(text: text, model: model)
        }
    }

    private func run(text: String, model: LLMModel) async {
        let stream = await driver.send(text: text, model: model)
        for await event in stream {
            await handle(event)
        }
        await refreshTranscript()
        streamingTail = nil
        isStreaming = false
        streamTask = nil
    }

    private func handle(_ event: ChatEvent) async {
        switch event {
        case .userMessageSaved(let userMessage):
            await refreshTranscript()
            await applyFallbackTitleIfNeeded(userText: userMessage.content)
        case .textDelta(let chunk):
            appendStreamingText(chunk)
        case .thinkingDelta(let chunk):
            appendStreamingThinking(chunk)
        case .toolCallStarted, .toolCallCompleted, .toolCallFailed:
            await refreshTranscript()
        case .assistantMessageSaved(let assistantMessage):
            // Clear the streaming text now that the canonical row exists.
            streamingTail = MessageListView.StreamingTail(
                thinking: "",
                thinkingStartedAt: nil,
                text: "",
                isCompacting: streamingTail?.isCompacting ?? false
            )
            await refreshTranscript()
            maybeGenerateTitle(from: assistantMessage)
        case .compactionStarted:
            streamingTail = MessageListView.StreamingTail(
                thinking: streamingTail?.thinking ?? "",
                thinkingStartedAt: streamingTail?.thinkingStartedAt,
                text: streamingTail?.text ?? "",
                isCompacting: true
            )
        case .compactionCompleted:
            streamingTail = MessageListView.StreamingTail(
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
                error = MessageListView.ErrorBanner(message: Self.describe(llmError))
            }
        }
    }

    private func appendStreamingText(_ chunk: String) {
        let current = streamingTail ?? .init(thinking: "", text: "", isCompacting: false)
        streamingTail = MessageListView.StreamingTail(
            thinking: current.thinking,
            thinkingStartedAt: current.thinkingStartedAt,
            text: current.text + chunk,
            isCompacting: current.isCompacting
        )
    }

    private func appendStreamingThinking(_ chunk: String) {
        let current = streamingTail ?? .init(thinking: "", text: "", isCompacting: false)
        streamingTail = MessageListView.StreamingTail(
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
            if case .userBubble(_, let text) = item { return text }
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
            self.error = MessageListView.ErrorBanner(
                message: "Could not load messages: \(error.localizedDescription)"
            )
        }
    }

    /// Project on-disk records into `MessageListView.Item`s. Pure
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
    ) -> [MessageListView.Item] {
        var items: [MessageListView.Item] = []
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
                items.append(.userBubble(id: message.id, text: message.content))
            case .assistant:
                let calls = (toolCallsByMessage[message.id] ?? []).map { call in
                    MessageListView.ToolCallView(
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

    private nonisolated static func mapStatus(_ status: ToolCallStatus) -> MessageListView.ToolCallView.Status {
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
/// `ChatSession+Driver.swift`.
public protocol ChatSessionDriver: Sendable {
    func send(text: String, model: LLMModel) async -> AsyncStream<ChatEvent>
}
