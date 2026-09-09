import Core
import Foundation

public enum CompactorError: Error, Sendable, Equatable {
    /// Reject empty summaries because persisting one would erase context from future prompts.
    case emptySummary
    case llmError(LLMError)
}

public actor Compactor {
    private let llmProviderRegistry: LLMProviderRegistry
    private let checkpointRepository: any CompactionCheckpointRepository
    private let estimator: any TokenEstimator
    private let clock: any Clock
    private let idGenerator: any IDGenerator

    public static let defaultKeepMostRecent = 4

    public init(
        llmProviderRegistry: LLMProviderRegistry,
        checkpointRepository: any CompactionCheckpointRepository,
        estimator: any TokenEstimator = HeuristicTokenEstimator(),
        clock: any Clock = SystemClock(),
        idGenerator: any IDGenerator = UUIDGenerator()
    ) {
        self.llmProviderRegistry = llmProviderRegistry
        self.checkpointRepository = checkpointRepository
        self.estimator = estimator
        self.clock = clock
        self.idGenerator = idGenerator
    }

    /// Side-effect-free preflight using the same slice selection as compact().
    public nonisolated func wouldCompact(
        messages: [MessageRecord],
        priorCheckpoint: CompactionCheckpointRecord?,
        keepMostRecent: Int = Compactor.defaultKeepMostRecent
    ) -> Bool {
        Compactor.messagesToSummarize(
            messages: messages,
            priorCheckpoint: priorCheckpoint,
            keepMostRecent: keepMostRecent
        ).last != nil
    }

    /// Pass full history ordered by createdAt and rowid. The new summary incorporates the prior checkpoint.
    /// Keep recent messages at a user boundary; return nil when no summarizable slice remains.
    public func compact(
        conversationId: String,
        messages: [MessageRecord],
        toolCalls: [ToolCallRecord],
        priorCheckpoint: CompactionCheckpointRecord?,
        model: LLMModel,
        keepMostRecent: Int = Compactor.defaultKeepMostRecent
    ) async throws -> CompactionCheckpointRecord? {
        let toSummarize = Compactor.messagesToSummarize(
            messages: messages,
            priorCheckpoint: priorCheckpoint,
            keepMostRecent: keepMostRecent
        )
        guard let lastSummarized = toSummarize.last else { return nil }

        let prompt = try buildSummarizationPrompt(
            messages: toSummarize,
            toolCalls: toolCalls,
            priorCheckpoint: priorCheckpoint
        )
        let provider = try await llmProviderRegistry.requireActive()
        let summary = try await runSummarization(provider: provider, model: model, prompt: prompt)
        guard !summary.isEmpty else { throw CompactorError.emptySummary }

        let checkpoint = CompactionCheckpointRecord(
            id: idGenerator.nextID(),
            conversationId: conversationId,
            uptoMessageId: lastSummarized.id,
            summary: summary,
            tokensBefore: estimator.estimate(messages: prompt),
            tokensAfter: estimator.estimate(summary),
            createdAt: clock.now(),
            isLive: true
        )
        try await checkpointRepository.save(checkpoint)
        return checkpoint
    }

    /// A stale checkpoint falls back to full history. Snap backward to a user boundary
    /// so the kept tail remains user-first and retains complete tool exchanges.
    /// Snapping forward could consume the newest tool results or empty the tail.
    static func messagesToSummarize(
        messages: [MessageRecord],
        priorCheckpoint: CompactionCheckpointRecord?,
        keepMostRecent: Int
    ) -> [MessageRecord] {
        let postCheckpoint = messagesAfterCheckpoint(messages, checkpoint: priorCheckpoint)
        guard postCheckpoint.count > keepMostRecent else { return [] }
        var cut = postCheckpoint.count - max(0, keepMostRecent)
        while cut > 0, cut < postCheckpoint.count, postCheckpoint[cut].role != .user {
            cut -= 1
        }
        return Array(postCheckpoint[..<cut])
    }

    static func messagesAfterCheckpoint(
        _ messages: [MessageRecord],
        checkpoint: CompactionCheckpointRecord?
    ) -> [MessageRecord] {
        guard let checkpoint else { return messages }
        guard let cutoff = messages.firstIndex(where: { $0.id == checkpoint.uptoMessageId }) else {
            return messages
        }
        return Array(messages[(cutoff + 1)...])
    }

    private func buildSummarizationPrompt(
        messages: [MessageRecord],
        toolCalls: [ToolCallRecord],
        priorCheckpoint: CompactionCheckpointRecord?
    ) throws -> [LLMMessage] {
        var prompt: [LLMMessage] = []
        prompt.append(LLMMessage(
            role: .system,
            text: """
                You are summarizing an earlier portion of a chat conversation \
                so it can be referenced later without keeping every message. \
                Produce a concise summary (3–8 sentences) that preserves: \
                participant decisions, named entities, outstanding questions, \
                and any tool results that affect future replies. Omit small \
                talk and rephrasing. Output the summary text only — no \
                preamble, no headings.
                """
        ))
        if let priorCheckpoint {
            prompt.append(LLMMessage(
                role: .system,
                text: "Earlier summary (already compacted):\n\n\(priorCheckpoint.summary)"
            ))
        }
        let projected = try ContextAssembler(estimator: estimator).assemble(
            messages: messages,
            toolCalls: toolCalls,
            checkpoint: nil,
            // Only the projected messages matter here; the stub model's context budget is unused.
            model: LLMModel(id: "summarization-stub", displayName: "stub")
        ).messages
        prompt.append(contentsOf: projected)
        prompt.append(LLMMessage(
            role: .user,
            text: "Summarize the conversation above per the system instructions."
        ))
        return prompt
    }

    private func runSummarization(
        provider: any LLMProvider,
        model: LLMModel,
        prompt: [LLMMessage]
    ) async throws -> String {
        let stream = provider.stream(messages: prompt, model: model, tools: [], temperature: 0.2)
        var summary = ""
        for try await event in stream {
            switch event {
            case .textDelta(_, let text):
                summary += text
            case .error(let err):
                throw CompactorError.llmError(err)
            case .messageStart, .contentBlockStart, .contentBlockStop,
                 .thinkingDelta, .thinkingSignature, .toolUse, .messageComplete,
                 .searchStarted, .citations, .searchSuggestionsHTML:
                break
            }
        }
        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
