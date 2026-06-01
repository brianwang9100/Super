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
    ///   - chatBriefing: The Chat-assistant base prompt, loaded once at
    ///     app launch from `Resources/DefaultSystemPrompt.md`. Rendered
    ///     under a `## Chat assistant` header inside the leading
    ///     concatenated `.system` block. Defaults to empty so fixtures
    ///     and tests that don't carry the Chat bundle continue to work.
    ///   - appletBriefings: Per-applet prompts contributed by registered
    ///     `MiniApplet`s, already trimmed and ordered (see
    ///     `AppletRegistry.resolvedBriefings()`). Each renders under its
    ///     own `## <Name> applet` header inside the leading block.
    ///   - userPersonalization: Free-form user text (was
    ///     `ChatSettings.systemPrompt`). Rendered under a
    ///     `## User personalization` header at the end of the leading
    ///     block so it follows — never overrides — the authoritative
    ///     chat and applet sections. Empty/whitespace skips injection.
    ///   - memories: Stored user-preference memories surfaced by the
    ///     `memory` tool. Rendered as a bulleted "What I remember about
    ///     you" block in its own `.system` message immediately after the
    ///     leading block (memories change far more frequently than the
    ///     chat/applet/personalization stack; keeping them in their own
    ///     block isolates the prompt-cache-busting churn). Each bullet
    ///     carries the entry's id (`- [<id>] <text>`) so the LLM can
    ///     call `memory(op:'update'|'forget', id:...)` in conversations
    ///     where it didn't perform the original `save` and therefore
    ///     has no other source for the id. Empty array = no block
    ///     injected.
    public func assemble(
        messages: [MessageRecord],
        toolCalls: [ToolCallRecord],
        checkpoint: CompactionCheckpointRecord?,
        model: LLMModel,
        chatBriefing: String = "",
        appletBriefings: [AppletBriefing] = [],
        userPersonalization: String = "",
        memories: [MemoryEntry] = []
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
        // Insert order is bottom-up — each `insert(at: 0)` puts the new
        // block ahead of everything inserted so far. The final on-the-wire
        // order is therefore:
        //   [leading block, memories, historical .system rows, checkpoint
        //    summary, user/assistant/tool history].
        // The leading block (chat assistant + applets + personalization)
        // sits first because it is the most stable across turns — the
        // Anthropic prompt cache rewards a stable prefix. Memories change
        // every time the `memory` tool runs, so they live in their own
        // block immediately after the leading one, isolating the cache
        // bust to just that block.
        if let memoriesBlock = Self.formatMemoriesBlock(memories) {
            prompt.insert(LLMMessage(role: .system, text: memoriesBlock), at: 0)
        }
        if let leadingBlock = Self.formatLeadingSystemBlock(
            chatBriefing: chatBriefing,
            appletBriefings: appletBriefings,
            userPersonalization: userPersonalization
        ) {
            prompt.insert(LLMMessage(role: .system, text: leadingBlock), at: 0)
        }
        // The projected prompt can carry several consecutive `.system`
        // entries (leading block, memories, historical leading `.system`
        // rows, checkpoint summary). The Anthropic Messages API accepts
        // that natively and `OpenAICompatibleLLMProvider` forwards each
        // one as its own message — which the OpenAI Chat Completions API
        // also accepts (it concatenates internally). If a future
        // provider with a stricter single-system contract is added,
        // merge these blocks into a single newline-joined `.system`
        // entry at this insertion point.
        let total = estimator.estimate(messages: prompt)
        return ContextAssembly(
            messages: prompt,
            totalTokens: total,
            maxTokens: model.maxContextTokens
        )
    }

    /// Concatenates the chat-assistant briefing, per-applet briefings, and
    /// user-personalization text into a single labeled markdown body, or
    /// returns `nil` when every section is empty. Each section is
    /// preceded by a `## <heading>` so the Large Language Model (LLM)
    /// can scope rules to the right applet and so user personalization is
    /// visibly distinct from authoritative orchestration text.
    static func formatLeadingSystemBlock(
        chatBriefing: String,
        appletBriefings: [AppletBriefing],
        userPersonalization: String
    ) -> String? {
        var sections: [String] = []
        let trimmedChat = chatBriefing.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedChat.isEmpty {
            sections.append("## Chat assistant\n\n\(trimmedChat)")
        }
        for briefing in appletBriefings {
            // Bodies are already trimmed by `AppletRegistry.resolvedBriefings()`,
            // but trim again defensively for callers that build briefings
            // by hand (tests, fixtures).
            let trimmedBody = briefing.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedBody.isEmpty else { continue }
            sections.append("## \(briefing.label)\n\n\(trimmedBody)")
        }
        let trimmedPersonalization = userPersonalization.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPersonalization.isEmpty {
            sections.append("## User personalization\n\n\(trimmedPersonalization)")
        }
        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }

    /// Format the bulleted "What I remember about you" block, or `nil`
    /// when there's nothing to surface (skipping the insert entirely
    /// avoids a stray blank `.system` row when memory is enabled but
    /// empty). Each bullet leads with `[<id>]` so the LLM can pass the
    /// id back to `memory(op:'update'|'forget', id:...)` in a follow-up
    /// turn — without it, those ops would only be callable on the same
    /// turn that produced the `save` artifact. Text is trimmed so the
    /// LLM doesn't see ragged whitespace from copy-pasted input.
    static func formatMemoriesBlock(_ memories: [MemoryEntry]) -> String? {
        let cleaned = memories
            .map { (id: $0.id, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        let bullets = cleaned.map { "- [\($0.id)] \($0.text)" }.joined(separator: "\n")
        return "What I remember about you:\n\(bullets)"
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
                llmMessages.append(LLMMessage(role: .user, text: Self.expandedUserText(for: record)))
            case .assistant:
                var blocks: [LLMContent] = []
                // Replay stored web-search results (with their encrypted echoes)
                // so providers that require it (Anthropic) keep prior-turn
                // citations valid. Gated on a present `providerEcho` — only
                // those carry the opaque blob worth round-tripping; OpenAI /
                // Gemini citations have none, so we don't emit a `.searchResult`
                // they'd just ignore. Positioned before the text block, matching
                // the on-the-wire order (results precede the text that cites
                // them); adapters that don't need it skip the block.
                if let sources = record.attachments?.sources,
                   sources.contains(where: { $0.providerEcho != nil }) {
                    blocks.append(.searchResult(sources))
                }
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

    /// A user row's text with any verse-reference attachments prepended as
    /// citation + verbatim snapshot blocks, so the model is handed exact
    /// scripture rather than asked to recall it (BYOK small/local models
    /// misquote translations). With no attachments this returns
    /// `record.content` unchanged; the on-disk `content` always stays the
    /// user's typed text only — the expansion exists only in the prompt.
    /// When the typed text is empty (a pill-only message) the result is
    /// just the reference blocks.
    static func expandedUserText(for record: MessageRecord) -> String {
        guard let references = record.attachments?.references, !references.isEmpty else {
            return record.content
        }
        let blocks = references.map { "[Bible — \($0.citation)]\n\($0.snapshot)" }
        let typed = record.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return (typed.isEmpty ? blocks : blocks + [typed]).joined(separator: "\n\n")
    }
}
