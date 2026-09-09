import Core
import Foundation
import Observation
import os

private let bibleAnnotateLog = Logger(
    subsystem: "com.brianwang.Super",
    category: "chat-session"
)

/// Foreground requests stream Markdown without chat rows and publish a correlated completion.
/// Bulk generate(reference:) retains its transient tool-loop conversation.
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

    public private(set) var inFlightRequestIDs: Set<String> = []

    private var subscriptionTask: Task<Void, Never>?
    /// Request-specific callbacks prevent unrelated bus traffic from prematurely satisfying tests.
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

    /// Attaches once; repeated calls are a no-op.
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
        guard inFlightRequestIDs.insert(reference.id).inserted else { return }
        // Dispatch concurrently; inherited MainActor isolation owns the in-flight request set.
        Task { [weak self] in
            guard let self else { return }
            let generator = BibleAnnotationStreamGenerator(
                providerRegistry: self.llmProviderRegistry,
                toolRegistry: self.toolRegistry
            )
            let outcome = await generator.generate(reference: reference) { text in
                await bus.publish(.bibleAnnotateProgress(requestId: reference.id, text: text))
            }
            self.inFlightRequestIDs.remove(reference.id)
            await bus.publish(.bibleAnnotateCompleted(
                requestId: reference.id,
                result: outcome.asResult
            ))
        }
        // Signal only after insertion and task creation so tests observe the request as in flight.
        let callbacks = requestCallbacks
        requestCallbacks.removeAll()
        for callback in callbacks { callback() }
    }

    /// Await transient-conversation cleanup before returning; cleanup failures are logged.
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

        // A successful tool call already persisted the annotation; a trailing stream error
        // must not turn it into a retryable failure. Count all artifacts for notable-verse bulk mode.
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

    /// Resolve from the active provider so the chosen model belongs to supportedModels.
    private func resolveActiveModel() async throws -> LLMModel {
        guard let provider = await llmProviderRegistry.active(),
              let model = provider.supportedModels.first else {
            throw DispatchPrepError.noActiveProvider
        }
        return model
    }

    private func failureMessage(for error: any Error) -> String {
        switch error {
        case DispatchPrepError.noActiveProvider:
            return "No LLM provider is configured. Add a model in Settings, then try again."
        default:
            return error.localizedDescription
        }
    }

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

    /// Credentials and rate limits stop the bulk run; other failures feed its consecutive-failure breaker.
    nonisolated static func classify(_ error: LLMError) -> BibleAnnotateFailure {
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

    /// Keep the tool ID literal so Chat does not import Bible.
    nonisolated static let bibleAnnotateToolID = "bible.annotate"

    /// Fires once after a request is recorded and its dispatch task starts.
    func _onNextAnnotateRequest(_ callback: @escaping @MainActor () -> Void) {
        requestCallbacks.append(callback)
    }

    static let dispatcherBriefing = """
    You are running as a one-off Bible annotation dispatcher inside the \
    Super app's headless tool pipeline.

    Your only job this turn is to call the `bible.annotate` tool exactly \
    once for the target the user describes, passing ONE markdown study \
    summary in `summary`. Do not respond conversationally, do not call \
    any other tool, do not ask follow-up questions. After the tool call \
    completes, end your turn.

    """ + "\n\n" + annotationWritingGuidance

    nonisolated static let annotationWritingGuidance = """
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

    static func briefing(forKind kind: String) -> String {
        kind == "chapterVerses" ? notableVersesBriefing : dispatcherBriefing
    }

    static func prompt(for reference: RecordReference) -> String {
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
        // Exact passage text prevents annotations from citing wording absent from this translation.
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

    /// Keep scope headings aligned with docs/SuperBible/ANNOTATIONS.md. Unknown kinds fall back to generic guidance.
    nonisolated static func sectionGuidance(forKind kind: String) -> String? {
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
