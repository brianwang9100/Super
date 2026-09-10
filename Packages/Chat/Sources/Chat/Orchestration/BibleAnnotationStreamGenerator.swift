import Core
import Foundation

/// Streams a foreground study note and saves only after successful terminal completion and EOF.
struct BibleAnnotationStreamGenerator: Sendable {
    let providerRegistry: LLMProviderRegistry
    let toolRegistry: ToolRegistry

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
            let stream = provider.stream(
                messages: [
                    LLMMessage(role: .system, text: Self.briefing),
                    LLMMessage(role: .user, text: Self.prompt(for: reference)),
                ],
                model: model,
                tools: [],
                temperature: 0.7,
                options: LLMRequestOptions(requiresCompleteResponse: true)
            )
            var text = ""
            var completed = false
            // Drain through EOF: a terminal event followed by an error must not save.
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .textDelta(_, let delta):
                    guard !completed else { throw BibleAnnotationStreamError.incomplete }
                    guard !delta.isEmpty else { continue }
                    text += delta
                    await onProgress(text)
                case .messageComplete:
                    completed = true
                case .toolUse:
                    throw BibleAnnotationStreamError.unexpectedTool
                case .error(let error):
                    throw error
                default:
                    break
                }
            }
            try Task.checkCancellation()
            guard completed else { throw BibleAnnotationStreamError.incomplete }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BibleAnnotationStreamError.empty
            }
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
    case invalidTarget, unavailableWriter, noProvider, incomplete, empty, unexpectedTool

    var errorDescription: String? {
        switch self {
        case .invalidTarget: "This passage could not be annotated. Select it again and retry."
        case .unavailableWriter: "Bible annotations are unavailable or disabled. Enable bible.annotate in Settings and try again."
        case .noProvider: "No LLM provider is configured. Add a model in Settings, then try again."
        case .incomplete: "The annotation was interrupted before it finished. Try again."
        case .empty: "The model returned an empty annotation. Try again or choose another model."
        case .unexpectedTool: "The model returned a tool call instead of an annotation. Try again."
        }
    }
}
