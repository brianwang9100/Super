import Core
import Foundation
import Observation
import os

/// Production diagnostics for `BibleAnnotateDispatcher`. File-scope so
/// every method shares one Logger instance, under the same
/// `chat-session` category the turn driver uses.
private let bibleAnnotateLog = Logger(
    subsystem: "com.brianwang.Super",
    category: "chat-session"
)

/// Headless `bible.annotate` dispatcher — the Chat-side counterpart of
/// the Bible UI's spark button, Annotate action tile, and empty
/// book-picker bubbles.
///
/// Mirrors `ChatReferenceInbox`'s shape: shell-owned, observable,
/// attaches to the `SuperEventBus` once at app bootstrap, drains
/// `SuperEvent.bibleAnnotateRequested` envelopes off the bus, and
/// publishes one `SuperEvent.bibleAnnotateCompleted` per request.
///
/// Each dispatch creates a *transient* `ConversationRecord` (filtered
/// out of the Chats list by `ActiveConversationsRequest`), runs one
/// `ChatSession.send(...)` turn against it with a one-tool
/// `ToolRegistry` exposing only `bible.annotate`, and hard-deletes the
/// transient row (cascading to its `messages` and `toolCalls`) when the
/// turn terminates. Net chat-DB cost at rest: zero.
@MainActor
@Observable
public final class BibleAnnotateDispatcher {
    private let conversationRepository: any ConversationRepository
    private let messageRepository: any MessageRepository
    private let toolCallRepository: any ToolCallRepository
    private let checkpointRepository: any CompactionCheckpointRepository
    private let modelConfigurationRepository: any ModelConfigurationRepository
    private let llmProviderRegistry: LLMProviderRegistry
    private let toolRegistry: ToolRegistry
    private let compactor: Compactor
    private let clock: any Clock
    private let idGenerator: any IDGenerator

    /// In-flight request ids. Observed by tests to await dispatcher
    /// drain — production code consumes `bibleAnnotateCompleted` events
    /// off the bus instead.
    public private(set) var inFlightRequestIDs: Set<String> = []

    private var subscriptionTask: Task<Void, Never>?
    /// One-shot callbacks fired after the dispatcher's subscription
    /// processes a `bibleAnnotateRequested` envelope — test seam,
    /// never observed in production. Scoped to request envelopes only
    /// (rather than "next event") so unrelated bus traffic — a
    /// concurrent `bibleAnnotateCompleted` from another dispatch, an
    /// `openRecord` from a Chat-side citation tap — doesn't race the
    /// callback ahead of the actual request handling and mislead a
    /// test assertion. Mirrors `BibleScreenViewModel`'s same-shape
    /// `_onNextDispatchCompletion`.
    private var requestCallbacks: [@MainActor () -> Void] = []

    public init(
        conversationRepository: any ConversationRepository,
        messageRepository: any MessageRepository,
        toolCallRepository: any ToolCallRepository,
        checkpointRepository: any CompactionCheckpointRepository,
        modelConfigurationRepository: any ModelConfigurationRepository,
        llmProviderRegistry: LLMProviderRegistry,
        toolRegistry: ToolRegistry,
        compactor: Compactor,
        clock: any Clock = SystemClock(),
        idGenerator: any IDGenerator = UUIDGenerator()
    ) {
        self.conversationRepository = conversationRepository
        self.messageRepository = messageRepository
        self.toolCallRepository = toolCallRepository
        self.checkpointRepository = checkpointRepository
        self.modelConfigurationRepository = modelConfigurationRepository
        self.llmProviderRegistry = llmProviderRegistry
        self.toolRegistry = toolRegistry
        self.compactor = compactor
        self.clock = clock
        self.idGenerator = idGenerator
    }

    /// Subscribe to the bus and start draining
    /// `bibleAnnotateRequested` events. Idempotent — a second call is a
    /// no-op so the shell can call it unconditionally after bootstrap.
    public func attach(to bus: SuperEventBus) async {
        guard subscriptionTask == nil else { return }
        let stream = await bus.events()
        subscriptionTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event, bus: bus)
            }
        }
    }

    private func handle(_ event: SuperEvent, bus: SuperEventBus) {
        guard case .bibleAnnotateRequested(let reference) = event else { return }
        inFlightRequestIDs.insert(reference.id)
        // Inherits @MainActor from the dispatcher so updates to
        // `inFlightRequestIDs` after the await happen on the main
        // actor without a nested `MainActor.run`. The Task isn't
        // awaited here — multiple dispatches can fan out and run
        // their LLM turns concurrently.
        Task { [weak self] in
            guard let self else { return }
            let result = await self.dispatch(reference: reference)
            self.inFlightRequestIDs.remove(reference.id)
            await bus.publish(.bibleAnnotateCompleted(
                requestId: reference.id,
                result: result
            ))
        }
        // Fire after the in-flight insert + dispatch spawn so a test
        // awaiting the callback observes both. Unlike a `defer`, this
        // sits *inside* the request-filtered branch so unrelated
        // events don't drain the queue prematurely.
        let callbacks = requestCallbacks
        requestCallbacks.removeAll()
        for callback in callbacks { callback() }
    }

    /// Run one headless dispatch end-to-end. Always awaits the
    /// transient-conversation hard-delete before returning so the chat
    /// DB is back to its prior state by the time the Bible side
    /// receives the completion event.
    private func dispatch(reference: RecordReference) async -> BibleAnnotateResult {
        let model: LLMModel
        do {
            model = try await resolveActiveModel()
        } catch {
            return .failure(message: failureMessage(for: error))
        }

        let conversationId = idGenerator.nextID()
        let now = clock.now()
        let conversation = ConversationRecord(
            id: conversationId,
            title: nil,
            kind: .transient,
            createdAt: now,
            updatedAt: now
        )
        do {
            try await conversationRepository.save(conversation)
        } catch {
            return .failure(message: failureMessage(for: error))
        }

        let result = await runTurn(
            conversationId: conversationId,
            model: model,
            reference: reference
        )

        do {
            try await conversationRepository.hardDelete(id: conversationId)
        } catch {
            bibleAnnotateLog.error(
                "transient conversation cleanup failed: \(String(describing: error), privacy: .public)"
            )
        }
        return result
    }

    /// Drive one `ChatSession.send(...)` turn and reduce its event
    /// stream to a `BibleAnnotateResult`. Extracted so `dispatch` keeps
    /// a flat narrative: prep, turn, cleanup.
    private func runTurn(
        conversationId: String,
        model: LLMModel,
        reference: RecordReference
    ) async -> BibleAnnotateResult {
        let session = ChatSession(
            conversationId: conversationId,
            messageRepository: messageRepository,
            toolCallRepository: toolCallRepository,
            checkpointRepository: checkpointRepository,
            llmProviderRegistry: llmProviderRegistry,
            toolRegistry: toolRegistry,
            compactor: compactor,
            clock: clock,
            idGenerator: idGenerator,
            autoCompactEnabled: false,
            chatBriefing: Self.dispatcherBriefing,
            appletBriefings: [],
            userPersonalization: ""
        )

        let prompt = Self.prompt(for: reference)
        let stream = await session.send(text: prompt, model: model)

        var annotationCount = 0
        var toolWasCalled = false
        var failureMessage: String?

        for await event in stream {
            switch event {
            case .toolCallCompleted(let record, let result):
                guard record.toolName == Self.bibleAnnotateToolID else { continue }
                if result.isError {
                    failureMessage = result.content
                } else {
                    toolWasCalled = true
                    annotationCount += result.artifacts
                        .filter { $0.type == "annotation" }
                        .count
                }
            case .toolCallFailed(let record, let message):
                guard record.toolName == Self.bibleAnnotateToolID else { continue }
                failureMessage = message
            case .error(let llmError):
                failureMessage = llmError.localizedDescription
            default:
                break
            }
        }

        if let message = failureMessage {
            return .failure(message: message)
        }
        if !toolWasCalled {
            return .failure(message: "The model didn't call bible.annotate. Try again or pick a different model.")
        }
        // Tool was called successfully — zero new rows is a valid
        // outcome (the tool's `replace` may have cleared an
        // already-present set without inserting new ones, or all
        // entries collided with existing rows). The Bible side reads
        // `.success` as "stop showing the running indicator"; the
        // sheet's reactive `@Query` is what determines whether cards
        // appear.
        return .success(annotationCount: annotationCount)
    }

    /// Resolve the user's currently-selected model into an `LLMModel`
    /// the active provider knows about. Throws on any missing piece
    /// (no provider registered, no row selected, the selected row's
    /// `modelId` isn't in `supportedModels`) so the caller can map to
    /// a `.failure` result with a clear reason.
    private func resolveActiveModel() async throws -> LLMModel {
        guard let provider = await llmProviderRegistry.active() else {
            throw DispatchPrepError.noActiveProvider
        }
        guard let configuration = try await modelConfigurationRepository.selected() else {
            throw DispatchPrepError.noSelectedModel
        }
        guard let match = provider.supportedModels.first(where: { $0.id == configuration.modelId }) else {
            throw DispatchPrepError.modelNotSupportedByProvider(configuration.modelId)
        }
        return match
    }

    /// Map a thrown error from any prep or save step to the
    /// human-readable string Bible shows next to its retry button.
    private func failureMessage(for error: any Error) -> String {
        switch error {
        case DispatchPrepError.noActiveProvider:
            return "No LLM provider is configured. Add a model in Settings, then try again."
        case DispatchPrepError.noSelectedModel:
            return "No model is selected. Pick a model in Settings, then try again."
        case DispatchPrepError.modelNotSupportedByProvider(let id):
            return "The selected model (\(id)) isn't available from the active provider."
        default:
            return error.localizedDescription
        }
    }

    private enum DispatchPrepError: Error {
        case noActiveProvider
        case noSelectedModel
        case modelNotSupportedByProvider(String)
    }

    /// Tool id we filter `ChatEvent.toolCallCompleted` /
    /// `.toolCallFailed` on. Held as a string literal here so Chat
    /// doesn't need to import Bible to read `AnnotateBibleTool.toolID`
    /// — Chat already references `bible.annotate` by name in the
    /// AppletBriefing aggregation path.
    static let bibleAnnotateToolID = "bible.annotate"

    /// Test seam: register a one-shot callback fired after the
    /// dispatcher processes a `bibleAnnotateRequested` envelope
    /// (in-flight insert recorded, dispatch task spawned). Scoped to
    /// request envelopes only so unrelated bus traffic doesn't drain
    /// the queue prematurely. Symmetric with `BibleScreenViewModel`'s
    /// `_onNextDispatchCompletion`. Underscored because it's a
    /// test-only surface, not stable API.
    func _onNextAnnotateRequest(_ callback: @escaping @MainActor () -> Void) {
        requestCallbacks.append(callback)
    }

    // MARK: - Prompts

    /// `chatBriefing` for the transient session. Replaces the real chat
    /// system prompt so the LLM treats this turn purely as a tool
    /// dispatcher, not a chatbot reply.
    static let dispatcherBriefing = """
    You are running as a one-off Bible annotation dispatcher inside the \
    Super app's headless tool pipeline.

    Your only job this turn is to call the `bible.annotate` tool exactly \
    once for the target the user describes. Do not respond \
    conversationally, do not call any other tool, do not ask follow-up \
    questions. After the tool call completes, end your turn.

    Default to 2–4 short annotation cards per target. Cards can mix \
    `text` (concise prose: author, context, key idea, plain-language \
    paraphrase) with `reference` (a single scripture citation when a \
    parallel passage is genuinely illuminating). Keep each body to ~240 \
    characters / ≤2 sentences. Plain-language titles like "Author", \
    "Historical context", "See also", "Key idea".
    """

    /// `send(text:)` payload — names the target structurally so even \
    /// weaker models can produce the right `bible.annotate` arguments.
    static func prompt(for reference: RecordReference) -> String {
        """
        Annotate this scripture target.

        Target kind: \(reference.kind)
        Reference id: \(reference.sourceID)
        Display: \(reference.displayLabel)
        Citation: \(reference.citation)

        Call `bible.annotate` once with arguments matching this target, \
        then end the turn.
        """
    }
}
