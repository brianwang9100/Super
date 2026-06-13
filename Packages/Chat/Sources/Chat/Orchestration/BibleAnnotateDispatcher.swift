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
public final class BibleAnnotateDispatcher: BibleAnnotateGenerating {
    private let conversationRepository: any ConversationRepository
    private let messageRepository: any MessageRepository
    private let toolCallRepository: any ToolCallRepository
    private let checkpointRepository: any CompactionCheckpointRepository
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
            let outcome = await self.generate(reference: reference)
            self.inFlightRequestIDs.remove(reference.id)
            await bus.publish(.bibleAnnotateCompleted(
                requestId: reference.id,
                // The bus / Bible UI only needs the message; flatten away the
                // classification (used by the bulk runner) so the event payload
                // is unchanged.
                result: outcome.asResult
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

    /// Run one headless generation end-to-end (the `BibleAnnotateGenerating`
    /// requirement). Always awaits the transient-conversation hard-delete before
    /// returning so the chat DB is back to its prior state by the time the
    /// caller (the bus handler, or the bulk runner) sees the outcome.
    public func generate(reference: RecordReference) async -> BibleAnnotateOutcome {
        let model: LLMModel
        do {
            model = try await resolveActiveModel()
        } catch {
            return failureOutcome(for: error)
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
            return failureOutcome(for: error)
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
    /// stream to a `BibleAnnotateOutcome`. Extracted so `generate` keeps
    /// a flat narrative: prep, turn, cleanup.
    private func runTurn(
        conversationId: String,
        model: LLMModel,
        reference: RecordReference
    ) async -> BibleAnnotateOutcome {
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
            chatBriefing: Self.briefing(forKind: reference.kind),
            appletBriefings: [],
            userPersonalization: ""
        )

        let prompt = Self.prompt(for: reference)
        let stream = await session.send(text: prompt, model: model)

        var annotationCount = 0
        var toolWasCalled = false
        // A tool error / failed call is transient (retry the unit); an LLM
        // stream error is classified by kind so the bulk runner can halt on
        // fatal auth/quota. The message stays exactly what it was before so the
        // flattened bus payload is unchanged.
        var failure: (message: String, classification: BibleAnnotateFailure)?

        for await event in stream {
            switch event {
            case .toolCallCompleted(let record, let result):
                guard record.toolName == Self.bibleAnnotateToolID else { continue }
                if result.isError {
                    failure = (result.content, .retryable)
                } else {
                    toolWasCalled = true
                    annotationCount += result.artifacts
                        .filter { $0.type == "annotation" }
                        .count
                }
            case .toolCallFailed(let record, let message):
                guard record.toolName == Self.bibleAnnotateToolID else { continue }
                failure = (message, .retryable)
            case .error(let llmError):
                failure = (llmError.localizedDescription, Self.classify(llmError))
            default:
                break
            }
        }

        // A successful `bible.annotate` call wins over a trailing error.
        // Once the tool ran cleanly the summary is already written to the
        // DB — the user sees the card — so a later stream `.error` or a
        // malformed *second* tool call must not flip the turn to `.failure`.
        // Doing so would surface a spurious "couldn't regenerate" toast over
        // a freshly-written card and, via the bulk generator seam, record a
        // succeeded unit as a retryable failure. Only when no successful call
        // happened do we report the captured failure (or the no-tool case).
        // (For the single-shot paths the count is always 1 per call under the
        // single-summary contract; for the bulk `chapterVerses` mode the model
        // calls the tool once per notable verse, so the reduce accumulates the
        // real verse count into `producedCount` — there the count is information.)
        if toolWasCalled {
            return .success(annotationCount: annotationCount)
        }
        if let failure {
            return .failure(message: failure.message, classification: failure.classification)
        }
        return .failure(
            message: "The model didn't call bible.annotate. Try again or pick a different model.",
            classification: .retryable
        )
    }

    /// Resolve the model the active provider serves — the same model
    /// normal chat sessions run against. Bootstrap seeds the active
    /// provider from the selected row (falling back to first-registered
    /// when that row's provider didn't register), and the shell then
    /// keeps it in sync with the chat composer's selection (the picked
    /// record id is promoted via `registry.setActive(id:)`). Every provider maps 1:1
    /// to a single model, so the active provider's sole model *is* the
    /// chat model. Deriving the model from the active provider
    /// (rather than cross-checking the persisted selection row) also
    /// guarantees membership in `supportedModels`, which is all
    /// `provider.stream(...)` validates. Throws only when no provider is
    /// registered/active so the caller can surface a clear reason.
    private func resolveActiveModel() async throws -> LLMModel {
        guard let provider = await llmProviderRegistry.active(),
              let model = provider.supportedModels.first else {
            throw DispatchPrepError.noActiveProvider
        }
        return model
    }

    /// Map a thrown error from any prep or save step to the
    /// human-readable string Bible shows next to its retry button.
    private func failureMessage(for error: any Error) -> String {
        switch error {
        case DispatchPrepError.noActiveProvider:
            return "No LLM provider is configured. Add a model in Settings, then try again."
        default:
            return error.localizedDescription
        }
    }

    /// Wrap a thrown prep/save error as a classified failure outcome. No active
    /// provider is a fatal config error (`.fatalAuth`); a thrown `LLMError` is
    /// classified by kind; anything else is treated as transient.
    private func failureOutcome(for error: any Error) -> BibleAnnotateOutcome {
        let classification: BibleAnnotateFailure
        switch error {
        case DispatchPrepError.noActiveProvider:
            classification = .fatalAuth
        case let llmError as LLMError:
            classification = Self.classify(llmError)
        default:
            classification = .retryable
        }
        return .failure(message: failureMessage(for: error), classification: classification)
    }

    /// Classify an `LLMError` for the bulk runner's circuit breaker. Only
    /// invalid-credentials and rate-limit/quota errors are fatal (retrying
    /// can't fix them and they risk the wallet); everything else — transient
    /// network/decoding failures, an unsupported model, a generic provider
    /// error — is retryable, and a persistent retryable trips the run's
    /// consecutive-failure breaker instead.
    private static func classify(_ error: LLMError) -> BibleAnnotateFailure {
        switch error {
        case .unauthorized:
            .fatalAuth
        case .rateLimited:
            .fatalQuota
        case .unsupportedModel, .providerError, .decodingFailed, .requestFailed, .cancelled:
            .retryable
        }
    }

    private enum DispatchPrepError: Error {
        case noActiveProvider
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
    once for the target the user describes, passing ONE markdown study \
    summary in `summary`. Do not respond conversationally, do not call \
    any other tool, do not ask follow-up questions. After the tool call \
    completes, end your turn.

    When the target's exact verse text is provided, base the summary on \
    that text — reason from it, and never reference words it does not \
    contain. Do NOT repeat the target's verse text verbatim in the \
    summary; the reader displays the text above it.

    Write long-form: roughly 150–400 words scaled to scope (a verse \
    range shorter, a whole book longer). Structure the summary with \
    short `###` headings, bold key terms, and bullet lists or \
    blockquotes where they genuinely help. When the user message lists \
    sections to cover, use one heading per section. Cite scripture with \
    the full book name in `Book Chapter:Verse` form (e.g. `Romans \
    8:28-30`, `Psalm 23`) — the reader turns exactly that format into \
    tappable links. Mention a cross-reference ONLY when the target text \
    directly quotes, alludes to, or cites that passage — e.g. a New \
    Testament verse drawing on the Old Testament; never a merely \
    thematically similar verse.
    """

    /// `chatBriefing` for the notable-verses bulk mode (`kind == "chapterVerses"`).
    /// Unlike `dispatcherBriefing`, this one asks the model to call
    /// `bible.annotate` *multiple* times in the turn — once per notable verse
    /// range it picks from the chapter — rather than exactly once. The dispatcher
    /// already counts artifacts across every call, so each verse annotation lands
    /// and is tallied into the unit's `producedCount`.
    static let notableVersesBriefing = """
    You are running as a one-off Bible annotation dispatcher inside the \
    Super app's headless tool pipeline.

    Your job this turn is to identify the most significant verse ranges in the \
    chapter the user provides — up to 5 of them — and call the `bible.annotate` \
    tool once for EACH, with `target` set to "verse". Choose passages a reader \
    would most want study notes on (key teachings, turning points, famous or \
    pivotal verses); a contiguous range that belongs together (e.g. a single \
    parable or argument) is one call. Do NOT annotate the whole chapter, do not \
    write a chapter-level summary, do not respond conversationally, and do not \
    call any other tool. Make at least one call. After the last call, end your turn.

    For each verse call, pass the correct `bookId`, `chapterNumber`, `verseStart`, \
    and `verseEnd` (read the verse numbers from the numbered text provided), and \
    ONE markdown study summary in `summary`. Base every summary strictly on the \
    provided verse text — never reference words it does not contain — and do NOT \
    repeat the verse text verbatim; the reader displays it above the summary.

    Keep each summary focused: roughly 120–250 words. Structure it with short \
    `###` headings, bold key terms, and lists or blockquotes where they genuinely \
    help. Cite scripture with the full book name in `Book Chapter:Verse` form \
    (e.g. `Romans 8:28-30`, `Psalm 23`) — the reader turns exactly that format \
    into tappable links. Mention a cross-reference ONLY when the verse directly \
    quotes, alludes to, or cites that passage; never a merely thematically \
    similar verse.
    """

    /// The `chatBriefing` to drive a dispatch turn for a given `reference.kind`.
    /// The notable-verses bulk mode (`"chapterVerses"`) gets the multi-call
    /// rank-and-generate briefing; every other kind (the single-shot book /
    /// chapter / verse-range paths) gets the one-call `dispatcherBriefing`.
    static func briefing(forKind kind: String) -> String {
        kind == "chapterVerses" ? notableVersesBriefing : dispatcherBriefing
    }

    /// `send(text:)` payload — names the target structurally so even
    /// weaker models can produce the right `bible.annotate` arguments,
    /// and names the per-scope sections to cover so generated summaries
    /// stay consistent across calls.
    static func prompt(for reference: RecordReference) -> String {
        // Assemble as blank-line-separated paragraphs so the optional
        // per-scope steer reads as its own block — and so dropping it
        // (unknown kind) still leaves clean spacing around the closing
        // instruction rather than a stray blank line.
        var paragraphs = [
            """
            Annotate this scripture target.

            Target kind: \(reference.kind)
            Reference id: \(reference.sourceID)
            Display: \(reference.displayLabel)
            Citation: \(reference.citation)
            """,
        ]
        if let sections = sectionGuidance(forKind: reference.kind) {
            paragraphs.append(sections)
        }
        // The exact verse text, when the Bible side captured it (chapter and
        // verse-range targets). Grounding the model in the actual translation
        // here is what stops annotations that reference words the passage
        // doesn't use. A whole-book target carries no snapshot (too large), so
        // the block is omitted and the prompt falls back to citation-only.
        if !reference.snapshot.isEmpty {
            paragraphs.append("""
                Exact text of the target — base the summary on this, and \
                do not reference words that aren't present here:

                \(reference.snapshot)
                """)
        }
        if reference.kind == "chapterVerses" {
            paragraphs.append("""
                Pick up to 5 of this chapter's most notable verse ranges and call \
                `bible.annotate` once for each — `target` "verse", with \
                `verseStart`/`verseEnd` from the numbered text above — then end \
                the turn.
                """)
        } else {
            paragraphs.append("""
                Call `bible.annotate` once with arguments matching this target, \
                then end the turn.
                """)
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// "Sections to cover" steer for an annotation `kind` — the `###`
    /// headings the one summary should carry per scope, mirroring
    /// `docs/SuperBible/ANNOTATIONS.md` §1 (keep the two in sync).
    /// `reference.kind` is the structural discriminator the Bible UI
    /// stamps onto the request — `"book"`, `"chapter"`, `"verseRange"`
    /// (note: *not* `"verse"`), or the bulk-only `"chapterVerses"`
    /// rank-and-generate mode (whose steer applies per verse range the
    /// model picks). Returns `nil` for an unrecognised kind so the prompt
    /// falls back to the generic briefing rather than asserting a wrong
    /// structure.
    static func sectionGuidance(forKind kind: String) -> String? {
        switch kind {
        case "book":
            """
            For this book, structure the summary around its authorship \
            and date, an overview of its argument and major themes, and \
            its historical setting — one short `###` section each.
            """
        case "chapter":
            """
            For this chapter, structure the summary around what the \
            chapter says (its argument or narrative), an outline of its \
            movements, and the key context a reader needs — one short \
            `###` section each.
            """
        case "verseRange":
            """
            For this verse range, structure the summary around its \
            meaning in plain language, the historical and literary \
            context, and any genuine cross-references (passages this \
            text directly quotes, alludes to, or cites — omit the \
            section entirely when there are none).
            """
        case "chapterVerses":
            """
            For each verse range you choose, structure its summary around \
            the passage's meaning in plain language, the historical and \
            literary context, and any genuine cross-references (passages it \
            directly quotes, alludes to, or cites — omit the section \
            entirely when there are none).
            """
        default:
            nil
        }
    }
}
