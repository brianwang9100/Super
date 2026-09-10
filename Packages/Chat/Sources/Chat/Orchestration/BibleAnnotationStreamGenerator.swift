import Core
import Foundation

/// Streams a foreground study note and saves only after successful terminal completion and EOF.
struct BibleAnnotationStreamGenerator: Sendable {
    let providerRegistry: LLMProviderRegistry
    let toolRegistry: ToolRegistry
    let clock: any Clock
    let idGenerator: any IDGenerator

    init(
        providerRegistry: LLMProviderRegistry,
        toolRegistry: ToolRegistry,
        clock: any Clock = SystemClock(),
        idGenerator: any IDGenerator = UUIDGenerator()
    ) {
        self.providerRegistry = providerRegistry
        self.toolRegistry = toolRegistry
        self.clock = clock
        self.idGenerator = idGenerator
    }

    func generate(
        reference: RecordReference,
        onProgress: @Sendable (String) async -> Void
    ) async -> BibleAnnotateOutcome {
        do {
            let target = try BibleAnnotationRequestTarget(reference: reference)
            let toolID = BibleAnnotateDispatcher.bibleAnnotateToolID
            guard let registration = await toolRegistry.registration(toolID: toolID),
                  registration.isEnabled, case .local = registration.execution else {
                throw BibleAnnotationStreamError.unavailableWriter
            }
            guard let provider = await providerRegistry.active(),
                  let model = provider.supportedModels.first else {
                throw BibleAnnotationStreamError.noProvider
            }
            try Task.checkCancellation()
            let session = try await ChatSession.makeEphemeral(
                provider: provider,
                toolRegistry: toolRegistry,
                briefing: Self.briefing,
                configuration: .init(tools: .disabled, requiresCompleteResponse: true),
                clock: clock,
                idGenerator: idGenerator
            )
            let text = try await response(
                from: session, model: model, prompt: Self.prompt(for: reference), onProgress: onProgress
            )
            try Task.checkCancellation()
            let result = try await toolRegistry.execute(toolID: toolID, input: target.parameters(summary: text))
            guard !result.isError else {
                return .failure(message: result.content, classification: .retryable)
            }
            return .success(annotationCount: result.artifacts.filter { $0.type == "annotation" }.count)
        } catch {
            let classification: BibleAnnotateFailure
            if let error = error as? LLMError {
                classification = BibleAnnotateDispatcher.classify(error)
            } else if error as? BibleAnnotationStreamError == .noProvider {
                classification = .fatalAuth
            } else {
                classification = .retryable
            }
            let message = error is CancellationError ? "Annotation generation was interrupted. Try again." : error.localizedDescription
            return .failure(message: message, classification: classification)
        }
    }

    private func response(
        from session: ChatSession,
        model: LLMModel,
        prompt: String,
        onProgress: @Sendable (String) async -> Void
    ) async throws -> String {
        try await withTaskCancellationHandler {
            let stream = await session.send(text: prompt, model: model)
            // Cancellation may have reached the handler before send installed its task.
            if Task.isCancelled { await session.cancel() }
            var text = ""
            var savedResponse: String?
            var failure: LLMError?
            for await event in stream {
                switch event {
                case .textDelta(let delta):
                    guard !delta.isEmpty else { continue }
                    text += delta
                    await onProgress(text)
                case .assistantMessageSaved(let message):
                    savedResponse = message.content
                case .error(let error):
                    failure = error
                default: break
                }
            }
            if Task.isCancelled { await session.cancel() }
            await session.waitUntilFinished()
            try Task.checkCancellation()
            if let failure { throw failure }
            guard let savedResponse else { throw BibleAnnotationStreamError.incomplete }
            return savedResponse
        } onCancel: {
            Task { await session.cancel() }
        }
    }

    static let briefing = """
    Write one Bible study annotation for the supplied target. Output only the \
    Markdown study note. Do not include a preamble, ask questions, or call tools.
    """ + "\n\n" + BibleAnnotateDispatcher.annotationWritingGuidance

    static func prompt(for reference: RecordReference) -> String {
        var paragraphs = ["""
            Annotate this scripture target.

            Target kind: \(reference.kind)
            Reference id: \(reference.sourceID)
            Display: \(reference.displayLabel)
            Citation: \(reference.citation)
            """,
        ]
        if let sections = BibleAnnotateDispatcher.sectionGuidance(forKind: reference.kind) {
            paragraphs.append(sections)
        }
        if !reference.snapshot.isEmpty {
            paragraphs.append("Exact text of the target — base the summary on this:\n\n\(reference.snapshot)")
        }
        return paragraphs.joined(separator: "\n\n")
    }
}

/// Preparation and generation failures leave existing saved notes intact.
enum BibleAnnotationStreamError: Error, Sendable, Equatable, LocalizedError {
    case invalidTarget, unavailableWriter, noProvider, incomplete

    var errorDescription: String? {
        switch self {
        case .invalidTarget: "This passage could not be annotated. Select it again and retry."
        case .unavailableWriter: "Bible annotations are unavailable or disabled. Enable bible.annotate in Settings and try again."
        case .noProvider: "No LLM provider is configured. Add a model in Settings, then try again."
        case .incomplete: "The annotation was interrupted before it finished. Try again."
        }
    }
}
