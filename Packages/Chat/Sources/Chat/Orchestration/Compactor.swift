import Core
import Foundation

/// Errors thrown by `Compactor`.
public enum CompactorError: Error, Sendable, Equatable {
    /// The active LLM (Large Language Model) provider returned a stream
    /// that closed without producing a non-empty summary. Treated as a
    /// hard failure rather than persisting an empty checkpoint, which
    /// would erase context on the next assembly pass.
    case emptySummary
    /// The provider stream surfaced a typed `LLMError` before it finished.
    case llmError(LLMError)
}

/// Issues a summarization turn through the active `LLMProvider` and
/// persists the resulting `CompactionCheckpointRecord`. Atomic with prior
/// live checkpoints — the repository demotes the previous live row in the
/// same write transaction as the new save.
///
/// Stateless beyond its injected dependencies; safe to share one instance
/// across every `ChatSession` in the store.
public actor Compactor {
    private let llmProviderRegistry: LLMProviderRegistry
    private let checkpointRepository: any CompactionCheckpointRepository
    private let estimator: any TokenEstimator
    private let clock: any Clock
    private let idGenerator: any IDGenerator

    /// Default number of most-recent messages kept verbatim outside the
    /// summary window. Picked to preserve the immediate back-and-forth
    /// (typically: last user prompt, last assistant reply, last tool
    /// round-trip pair) while still freeing context further back.
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

    /// Run a compaction pass for `conversationId`.
    ///
    /// - Parameters:
    ///   - messages: Full conversation history in `(createdAt, rowid)`
    ///     ascending order. The compactor itself decides which slice to
    ///     summarize; the caller passes everything currently on disk.
    ///   - toolCalls: Tool-call rows for the conversation, used to project
    ///     the messages-to-summarize back into `LLMMessage`s for the
    ///     summarization prompt.
    ///   - priorCheckpoint: Latest live checkpoint, or nil. When present,
    ///     its summary feeds the new summarization request as a system
    ///     anchor so the new summary subsumes the old one.
    ///   - model: Active model (used as the summarization target — the
    ///     same model the user is chatting with, no separate cheap
    ///     tier in MVP).
    ///   - keepMostRecent: How many trailing messages to leave outside
    ///     the summary window. Default 4.
    /// - Returns: The persisted new checkpoint, or nil when there's
    ///   nothing to summarize (fewer than `keepMostRecent + 1` messages
    ///   beyond the prior checkpoint).
    /// Predicate: would `compact(...)` produce a checkpoint for the given
    /// inputs? Pure (no I/O — does not call the LLM or touch the database)
    /// so callers can cheaply decide whether to start a compaction pass
    /// without paying for one. The exact same slicing rules `compact(...)`
    /// uses internally, so the two can never disagree about whether work
    /// exists.
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

    /// Single source of truth for "which messages should this compaction
    /// pass actually summarize." Used both by `compact(...)`'s body and
    /// `wouldCompact(...)`'s pre-flight so the two paths cannot drift.
    /// Stale `priorCheckpoint` (an `uptoMessageId` not present in
    /// `messages`) falls back to the full message list — losing the tail
    /// is worse than ignoring a stale row.
    static func messagesToSummarize(
        messages: [MessageRecord],
        priorCheckpoint: CompactionCheckpointRecord?,
        keepMostRecent: Int
    ) -> [MessageRecord] {
        let postCheckpoint = messagesAfterCheckpoint(messages, checkpoint: priorCheckpoint)
        guard postCheckpoint.count > keepMostRecent else { return [] }
        return Array(postCheckpoint.dropLast(max(0, keepMostRecent)))
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
            // The model passed here only feeds maxTokens into the
            // returned `ContextAssembly` — we discard the assembly and
            // keep just the projected `messages`, so this stub model is
            // a deliberate "we don't need the budget" signal.
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
                 .thinkingDelta, .toolUse, .messageComplete,
                 .searchStarted, .citations, .searchSuggestionsHTML:
                break
            }
        }
        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
