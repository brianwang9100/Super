import Core
import Foundation

public struct ContextAssembly: Sendable, Equatable {
    public let messages: [LLMMessage]
    public let totalTokens: Int
    /// Prompt cost that survives compaction: injected system blocks, tools, and fixed allowance.
    public let fixedTokens: Int
    public let maxTokens: Int

    public init(messages: [LLMMessage], totalTokens: Int, fixedTokens: Int = 0, maxTokens: Int) {
        self.messages = messages
        self.totalTokens = totalTokens
        self.fixedTokens = fixedTokens
        self.maxTokens = maxTokens
    }

    /// Returns zero for a misconfigured nonpositive context window.
    public var ratio: Double {
        guard maxTokens > 0 else { return 0 }
        return Double(totalTokens) / Double(maxTokens)
    }

    public func isOverThreshold(_ threshold: Double) -> Bool {
        ratio >= threshold
    }

    public var compressibleTokens: Int { max(0, totalTokens - fixedTokens) }

    /// History usage against capacity remaining after the fixed prompt floor.
    public var compressibleRatio: Double {
        let available = maxTokens - fixedTokens
        guard available > 0 else { return compressibleTokens > 0 ? .infinity : 0 }
        return Double(compressibleTokens) / Double(available)
    }

    public func isCompressibleOverThreshold(_ threshold: Double) -> Bool {
        compressibleRatio >= threshold
    }
}

public struct ContextAssembler: Sendable {
    private let estimator: any TokenEstimator

    public init(estimator: any TokenEstimator = HeuristicTokenEstimator()) {
        self.estimator = estimator
    }

    /// `messages` must use repository order: `(createdAt, rowid)` ascending.
    public func assemble(
        messages: [MessageRecord],
        toolCalls: [ToolCallRecord],
        checkpoint: CompactionCheckpointRecord?,
        model: LLMModel,
        chatBriefing: String = "",
        appletBriefings: [AppletBriefing] = [],
        userPersonalization: String = "",
        memories: [MemoryEntry] = [],
        tools: [LLMTool] = []
    ) throws -> ContextAssembly {
        let kept = messagesAfterCheckpoint(messages, checkpoint: checkpoint)
        var prompt = try project(messages: kept, toolCalls: toolCalls, activeModelId: model.id)
        if let checkpoint {
            // Preserve leading system rows covered by the checkpoint.
            let systemPrefix = try project(
                messages: leadingSystemRowsCovered(by: checkpoint, in: messages),
                toolCalls: toolCalls,
                activeModelId: model.id
            )
            prompt.insert(checkpointMessage(for: checkpoint), at: 0)
            prompt.insert(contentsOf: systemPrefix, at: 0)
        }
        // Insert bottom-up: stable briefing, volatile memories, preserved system rows, summary, history.
        var fixedBlockTokens = 0
        if let memoriesBlock = Self.formatMemoriesBlock(memories) {
            prompt.insert(LLMMessage(role: .system, text: memoriesBlock), at: 0)
            fixedBlockTokens += estimator.estimate(memoriesBlock)
        }
        // Anthropic caches the stable briefing prefix separately from volatile memories.
        if let webSearchBlock = Self.formatWebSearchBlock(model: model) {
            prompt.insert(LLMMessage(role: .system, text: webSearchBlock, cacheHint: .stablePrefix), at: 0)
            fixedBlockTokens += estimator.estimate(webSearchBlock)
        }
        if let leadingBlock = Self.formatLeadingSystemBlock(
            chatBriefing: chatBriefing,
            appletBriefings: appletBriefings,
            userPersonalization: userPersonalization
        ) {
            prompt.insert(LLMMessage(role: .system, text: leadingBlock, cacheHint: .stablePrefix), at: 0)
            fixedBlockTokens += estimator.estimate(leadingBlock)
        }
        // Tool schemas consume context even though they sit outside `messages`.
        var toolTokens = estimator.estimate(tools: tools)
        var allowanceTokens = 0
        if ModelContextTier(maxContextTokens: model.maxContextTokens) == .compact {
            // AFM reports roughly 11K tokens for requests our raw heuristic estimates near 3K.
            toolTokens = Int((Double(toolTokens) * Self.compactTierToolSchemaInflation).rounded(.up))
            allowanceTokens = Self.compactTierFixedOverheadTokens
        }
        let total = estimator.estimate(messages: prompt) + toolTokens + allowanceTokens
        return ContextAssembly(
            messages: prompt,
            totalTokens: total,
            fixedTokens: fixedBlockTokens + toolTokens + allowanceTokens,
            maxTokens: model.maxContextTokens
        )
    }

    /// Compensates for on-device JSON-schema scaffolding absent from the heuristic.
    static let compactTierToolSchemaInflation: Double = 1.8

    /// Allowance for compact-tier provider instructions that the app cannot inspect.
    static let compactTierFixedOverheadTokens = 800

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

    static func formatWebSearchBlock(model: LLMModel) -> String? {
        guard NativeWebSearch.usesNativeSearch(model) else { return nil }
        return """
        ## Web search

        You can search the web for current, recent, or fast-changing facts \
        that fall outside your training knowledge. Search only when the \
        answer genuinely depends on such information or the user explicitly \
        asks — prefer your own knowledge for stable facts, and use a single \
        well-formed query. A search may require the user's approval and costs \
        money, so be economical: don't search for things you already know. \
        When you do use web results, ground your claims in them and cite the \
        sources you relied on.
        """
    }

    /// Includes stable IDs so later turns can update or forget an entry.
    static func formatMemoriesBlock(_ memories: [MemoryEntry]) -> String? {
        let cleaned = memories
            .map { (id: $0.id, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        let bullets = cleaned.map { "- [\($0.id)] \($0.text)" }.joined(separator: "\n")
        return "What I remember about you:\n\(bullets)"
    }

    /// Preserves only the leading system prefix covered by the checkpoint.
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
        // A stale checkpoint keeps all messages rather than risking tail loss.
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
        toolCalls: [ToolCallRecord],
        activeModelId: String
    ) throws -> [LLMMessage] {
        var toolCallsByMessageID: [String: [ToolCallRecord]] = [:]
        var toolCallsByID: [String: ToolCallRecord] = [:]
        for record in toolCalls {
            toolCallsByMessageID[record.messageId, default: []].append(record)
            toolCallsByID[record.id] = record
        }

        // Every tool use needs a later result. Synthesize missing results and drop results
        // without a preceding use after cancellation, crashes, or compaction.
        var messageIndexByID: [String: Int] = [:]
        var resultRowIndicesByCallID: [String: [Int]] = [:]
        for (index, record) in messages.enumerated() {
            messageIndexByID[record.id] = index
            if record.role == .tool, let callId = record.toolCallId {
                resultRowIndicesByCallID[callId, default: []].append(index)
            }
        }
        var resolvedToolCallIDs = Set<String>()
        for call in toolCalls {
            guard let parentIndex = messageIndexByID[call.messageId] else { continue }
            let followsParent = resultRowIndicesByCallID[call.id]?
                .contains { $0 > parentIndex } ?? false
            if followsParent { resolvedToolCallIDs.insert(call.id) }
        }
        var projectedToolUseIDs = Set<String>()

        var llmMessages: [LLMMessage] = []
        for record in messages {
            switch record.role {
            case .system:
                llmMessages.append(LLMMessage(role: .system, text: record.content))
            case .user:
                llmMessages.append(LLMMessage(role: .user, text: Self.expandedUserText(for: record)))
            case .assistant:
                var blocks: [LLMContent] = []
                // Anthropic requires signed thinking first and verbatim in a tool-loop replay.
                //
                // Thinking signatures are model-specific; omit them after a model switch.
                if let thinking = record.thinkingContent, !thinking.isEmpty {
                    let signature = record.thinkingModelId == activeModelId
                        ? record.thinkingSignature
                        : nil
                    blocks.append(.thinking(content: thinking, signature: signature))
                }
                // Replay opaque search echoes before cited text for providers such as Anthropic.
                if let sources = record.attachments?.sources,
                   sources.contains(where: { $0.providerEcho != nil }) {
                    blocks.append(.searchResult(sources))
                }
                if !record.content.isEmpty {
                    blocks.append(.text(record.content))
                }
                let calls = toolCallsByMessageID[record.id] ?? []
                for call in calls {
                    let input = try call.decodedParameters()
                    // Gemini requires its continuation signature on replayed function calls.
                    blocks.append(.toolUse(
                        id: call.id,
                        name: call.toolName,
                        input: input,
                        signature: call.signature
                    ))
                    projectedToolUseIDs.insert(call.id)
                }
                if !blocks.isEmpty {
                    llmMessages.append(LLMMessage(role: .assistant, content: blocks))
                }
                // Synthesize results for calls whose result row never landed
                // (see the pairing-totality note above). Placed directly
                // after the issuing assistant turn — any real sibling result
                // rows follow immediately in `messages`, so the pair group
                // stays contiguous on the wire.
                for call in calls where !resolvedToolCallIDs.contains(call.id) {
                    llmMessages.append(LLMMessage(role: .tool, content: [
                        .toolResult(
                            toolUseID: call.id,
                            content: "Tool execution was interrupted before producing a result. Treat this call as failed.",
                            isError: true
                        ),
                    ]))
                }
            case .tool:
                guard let toolCallID = record.toolCallId else { continue }
                // Drop a result row whose `tool_use` was never projected —
                // see the pairing-totality note above.
                guard projectedToolUseIDs.contains(toolCallID) else { continue }
                let isError = toolCallsByID[toolCallID]?.status == .failed
                llmMessages.append(LLMMessage(role: .tool, content: [
                    .toolResult(toolUseID: toolCallID, content: record.content, isError: isError),
                ]))
            }
        }
        return llmMessages
    }

    /// Prepends verbatim verse snapshots in the prompt so small/local models cannot misquote them.
    static func expandedUserText(for record: MessageRecord) -> String {
        guard let references = record.attachments?.references, !references.isEmpty else {
            return record.content
        }
        let blocks = references.map { "[Bible — \($0.citation)]\n\($0.snapshot)" }
        let typed = record.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return (typed.isEmpty ? blocks : blocks + [typed]).joined(separator: "\n\n")
    }
}
