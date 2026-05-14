import Core
import Foundation

/// Result of one assembly pass. The orchestrator hands `messages` straight
/// to `LLMProvider.stream(...)` and consults `isOverThreshold(_:)` to
/// decide whether to compact first.
public struct ContextAssembly: Sendable, Equatable {
    /// Prompt projected from the persisted history (with the live
    /// checkpoint, if any, prepended as a synthetic system message).
    public let messages: [LLMMessage]
    /// Token estimate for `messages` per the assembler's `TokenEstimator`.
    public let totalTokens: Int
    /// `LLMModel.maxContextTokens` as supplied at assembly time.
    public let maxTokens: Int

    public init(messages: [LLMMessage], totalTokens: Int, maxTokens: Int) {
        self.messages = messages
        self.totalTokens = totalTokens
        self.maxTokens = maxTokens
    }

    /// Fraction of the model's context window the prompt currently fills.
    /// Returns 0 when `maxTokens <= 0` rather than crashing on a misconfigured
    /// model — a misconfigured ratio simply suppresses auto-compaction.
    public var ratio: Double {
        guard maxTokens > 0 else { return 0 }
        return Double(totalTokens) / Double(maxTokens)
    }

    /// `true` when `ratio >= threshold`. The orchestrator drives
    /// auto-compaction off this. Threshold is read from settings; default
    /// `ChatSettings.defaultAutoCompactThreshold`.
    public func isOverThreshold(_ threshold: Double) -> Bool {
        ratio >= threshold
    }
}

/// Projects persisted Chat rows into the `[LLMMessage]` array shipped to a
/// provider, folding the live `CompactionCheckpointRecord` (if any) in as
/// a single leading system message that replaces the messages it covers.
///
/// Walks the inputs newest-first to find the cutoff implied by
/// `checkpoint.uptoMessageId` (inclusive); messages at or before the cutoff
/// are dropped from the prompt and the summary stands in for them.
public struct ContextAssembler: Sendable {
    private let estimator: any TokenEstimator

    public init(estimator: any TokenEstimator = HeuristicTokenEstimator()) {
        self.estimator = estimator
    }

    /// - Parameters:
    ///   - messages: Conversation history in `(createdAt, rowid)` ascending
    ///     order — exactly what `MessageRepository.fetchAll(conversationId:)`
    ///     returns.
    ///   - toolCalls: Tool-call rows for the conversation, used to fold
    ///     `.toolUse` blocks back onto assistant messages and to mark
    ///     `isError: true` on tool-result rows whose call failed.
    ///   - checkpoint: Latest live compaction checkpoint, or nil.
    ///   - model: Active model — its `maxContextTokens` drives the budget.
    ///   - systemPrompt: The user's configured system prompt from
    ///     `ChatSettings.systemPrompt`. Trimmed; if non-empty, prepended
    ///     as the very first `.system` LLMMessage (before any historical
    ///     `.system` rows and before the checkpoint summary) so it always
    ///     reflects current settings rather than a snapshot baked into
    ///     the conversation. Defaults to empty (no injection) to keep
    ///     callers that don't carry settings — fixtures, snapshots —
    ///     working unchanged.
    public func assemble(
        messages: [MessageRecord],
        toolCalls: [ToolCallRecord],
        checkpoint: CompactionCheckpointRecord?,
        model: LLMModel,
        systemPrompt: String = ""
    ) throws -> ContextAssembly {
        let kept = messagesAfterCheckpoint(messages, checkpoint: checkpoint)
        var prompt = try project(messages: kept, toolCalls: toolCalls)
        if let checkpoint {
            // Re-emit any `.system` rows that the checkpoint window
            // covered, so the conversation's original system prompt
            // doesn't get summarized away. The summary itself is then
            // inserted right after them as a synthetic system row.
            let systemPrefix = try project(
                messages: leadingSystemRowsCovered(by: checkpoint, in: messages),
                toolCalls: toolCalls
            )
            prompt.insert(checkpointMessage(for: checkpoint), at: 0)
            prompt.insert(contentsOf: systemPrefix, at: 0)
        }
        let trimmedSystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystemPrompt.isEmpty {
            prompt.insert(LLMMessage(role: .system, text: trimmedSystemPrompt), at: 0)
        }
        let total = estimator.estimate(messages: prompt)
        return ContextAssembly(
            messages: prompt,
            totalTokens: total,
            maxTokens: model.maxContextTokens
        )
    }

    /// Returns the `.system` rows that sit at or before the checkpoint's
    /// `uptoMessageId` — the rows we'd otherwise drop. Stops at the first
    /// non-`.system` row so a mid-conversation `.system` insertion (rare,
    /// but possible) still gets summarized; only a true *leading*
    /// system-prompt prefix is preserved verbatim.
    private func leadingSystemRowsCovered(
        by checkpoint: CompactionCheckpointRecord,
        in messages: [MessageRecord]
    ) -> [MessageRecord] {
        guard messages.contains(where: { $0.id == checkpoint.uptoMessageId }) else {
            return []
        }
        var systemRows: [MessageRecord] = []
        for record in messages {
            guard record.role == .system else { break }
            systemRows.append(record)
        }
        return systemRows
    }

    private func messagesAfterCheckpoint(
        _ messages: [MessageRecord],
        checkpoint: CompactionCheckpointRecord?
    ) -> [MessageRecord] {
        guard let checkpoint else { return messages }
        // `uptoMessageId` is inclusive; drop everything up to and including
        // that row. If the id is absent (deleted message, mismatched
        // conversation) fall back to keeping every message — losing the
        // tail is worse than ignoring a stale checkpoint.
        guard let cutoff = messages.firstIndex(where: { $0.id == checkpoint.uptoMessageId }) else {
            return messages
        }
        return Array(messages[(cutoff + 1)...])
    }

    private func checkpointMessage(for checkpoint: CompactionCheckpointRecord) -> LLMMessage {
        // Phrased as a system note so the LLM treats it as authoritative
        // background, not user-provided text.
        let text = "Summary of earlier conversation (compacted):\n\n\(checkpoint.summary)"
        return LLMMessage(role: .system, text: text)
    }

    private func project(
        messages: [MessageRecord],
        toolCalls: [ToolCallRecord]
    ) throws -> [LLMMessage] {
        var toolCallsByMessageID: [String: [ToolCallRecord]] = [:]
        var toolCallsByID: [String: ToolCallRecord] = [:]
        for record in toolCalls {
            toolCallsByMessageID[record.messageId, default: []].append(record)
            toolCallsByID[record.id] = record
        }

        var llmMessages: [LLMMessage] = []
        for record in messages {
            switch record.role {
            case .system:
                llmMessages.append(LLMMessage(role: .system, text: record.content))
            case .user:
                llmMessages.append(LLMMessage(role: .user, text: record.content))
            case .assistant:
                var blocks: [LLMContent] = []
                if !record.content.isEmpty {
                    blocks.append(.text(record.content))
                }
                for call in toolCallsByMessageID[record.id] ?? [] {
                    let input = try call.decodedParameters()
                    blocks.append(.toolUse(id: call.id, name: call.toolName, input: input))
                }
                if !blocks.isEmpty {
                    llmMessages.append(LLMMessage(role: .assistant, content: blocks))
                }
            case .tool:
                guard let toolCallID = record.toolCallId else { continue }
                let isError = toolCallsByID[toolCallID]?.status == .failed
                llmMessages.append(LLMMessage(role: .tool, content: [
                    .toolResult(toolUseID: toolCallID, content: record.content, isError: isError),
                ]))
            }
        }
        return llmMessages
    }
}
