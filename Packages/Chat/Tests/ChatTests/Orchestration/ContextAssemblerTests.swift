import Core
import Foundation
import Testing

@testable import Chat

@Suite("ContextAssembler")
struct ContextAssemblerTests {

    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeMessage(
        id: String,
        role: MessageRole,
        content: String,
        offset: TimeInterval,
        toolCallId: String? = nil
    ) -> MessageRecord {
        MessageRecord(
            id: id,
            conversationId: "conv-1",
            role: role,
            content: content,
            toolCallId: toolCallId,
            createdAt: baseDate.addingTimeInterval(offset)
        )
    }

    /// Default to full tier to isolate raw estimates from compact-tier calibration.
    private func makeModel(maxContextTokens: Int = 100_000) -> LLMModel {
        LLMModel(
            id: "test-model",
            displayName: "Test",
            supportsThinking: false,
            supportsTools: true,
            maxContextTokens: maxContextTokens
        )
    }

    private func makeTool(name: String, description: String) -> LLMTool {
        LLMTool(
            id: name,
            name: name,
            description: description,
            category: .query,
            parameters: [
                LLMToolParameter(name: "query", type: .string, description: "What to look up."),
            ],
            appletId: "test"
        )
    }

    @Test func toolSchemasRaiseTotalTokens() throws {
        let assembler = ContextAssembler()
        let messages = [makeMessage(id: "m1", role: .user, content: "Hi", offset: 0)]
        let withoutTools = try assembler.assemble(
            messages: messages, toolCalls: [], checkpoint: nil, model: makeModel()
        )
        let withTools = try assembler.assemble(
            messages: messages, toolCalls: [], checkpoint: nil, model: makeModel(),
            tools: [makeTool(name: "search", description: "Search the corpus for a phrase.")]
        )
        #expect(withTools.totalTokens > withoutTools.totalTokens)
    }

    @Test func toolSchemasCanTipOverThreshold() throws {
        // Use full tier so only schema weight changes; compact calibration adds a fixed allowance.
        let assembler = ContextAssembler()
        let messages = [makeMessage(id: "m1", role: .user, content: "Hi", offset: 0)]
        let model = makeModel(maxContextTokens: 10_000)
        let verboseTool = makeTool(
            name: "annotate",
            description: String(repeating: "Annotate a passage with study notes. ", count: 1_000)
        )
        let withoutTools = try assembler.assemble(
            messages: messages, toolCalls: [], checkpoint: nil, model: model
        )
        let withTools = try assembler.assemble(
            messages: messages, toolCalls: [], checkpoint: nil, model: model,
            tools: [verboseTool]
        )
        #expect(withoutTools.isOverThreshold(0.85) == false)
        #expect(withTools.isOverThreshold(0.85) == true)
    }

    @Test func compactTierInflatesToolSchemasAndAddsFixedAllowance() throws {
        // Compact calibration accounts for schema scaffolding and hidden provider instructions.
        let assembler = ContextAssembler()
        let messages = [makeMessage(id: "m1", role: .user, content: "Hi", offset: 0)]
        let tools = [makeTool(name: "search", description: "Search the corpus for a phrase.")]

        let fullNoTools = try assembler.assemble(
            messages: messages, toolCalls: [], checkpoint: nil, model: makeModel()
        )
        let fullWithTools = try assembler.assemble(
            messages: messages, toolCalls: [], checkpoint: nil, model: makeModel(), tools: tools
        )
        let rawToolTokens = fullWithTools.totalTokens - fullNoTools.totalTokens

        let compactNoTools = try assembler.assemble(
            messages: messages, toolCalls: [], checkpoint: nil,
            model: makeModel(maxContextTokens: 4_096)
        )
        #expect(
            compactNoTools.totalTokens
                == fullNoTools.totalTokens + ContextAssembler.compactTierFixedOverheadTokens
        )
        #expect(compactNoTools.fixedTokens == ContextAssembler.compactTierFixedOverheadTokens)

        let compactWithTools = try assembler.assemble(
            messages: messages, toolCalls: [], checkpoint: nil,
            model: makeModel(maxContextTokens: 4_096), tools: tools
        )
        let inflatedToolTokens = Int(
            (Double(rawToolTokens) * ContextAssembler.compactTierToolSchemaInflation).rounded(.up)
        )
        #expect(
            compactWithTools.totalTokens
                == fullNoTools.totalTokens + inflatedToolTokens
                    + ContextAssembler.compactTierFixedOverheadTokens
        )
        #expect(
            compactWithTools.fixedTokens
                == inflatedToolTokens + ContextAssembler.compactTierFixedOverheadTokens
        )
        #expect(compactWithTools.compressibleTokens == fullNoTools.totalTokens)
        #expect(fullWithTools.fixedTokens == rawToolTokens)
    }

    @Test func fixedTokensIncludeAssemblerInjectedSystemBlocks() throws {
        // Injected instructions survive checkpoints and belong in the fixed floor.
        let assembler = ContextAssembler()
        let messages = [makeMessage(id: "m1", role: .user, content: "Hi", offset: 0)]
        let assembly = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: nil,
            model: makeModel(maxContextTokens: 4_096),
            chatBriefing: String(repeating: "Be concise. ", count: 50)
        )
        #expect(assembly.compressibleTokens == 1)
        #expect(assembly.fixedTokens == assembly.totalTokens - 1)
    }

    @Test func noCheckpointReturnsAllMessagesProjected() throws {
        let assembler = ContextAssembler()
        let messages: [MessageRecord] = [
            makeMessage(id: "m1", role: .user, content: "Hi", offset: 0),
            makeMessage(id: "m2", role: .assistant, content: "Hello", offset: 1),
            makeMessage(id: "m3", role: .user, content: "How are you?", offset: 2),
        ]

        let assembly = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: nil,
            model: makeModel()
        )

        #expect(assembly.messages.count == 3)
        #expect(assembly.messages.map(\.role) == [.user, .assistant, .user])
    }

    @Test func webSearchBlockPresentOnlyForNativeSearchModels() {
        let native = LLMModel(id: "n", displayName: "N", searchBackend: "native")
        let plain = LLMModel(id: "p", displayName: "P", searchBackend: nil)
        let block = ContextAssembler.formatWebSearchBlock(model: native)
        #expect(block?.contains("## Web search") == true)
        #expect(block?.contains("cite") == true)
        #expect(ContextAssembler.formatWebSearchBlock(model: plain) == nil)
    }

    @Test func nativeSearchModelPromptCarriesWebSearchSystemRow() throws {
        let assembler = ContextAssembler()
        let native = LLMModel(
            id: "native", displayName: "Native", maxContextTokens: 1_000, searchBackend: "native"
        )
        let assembly = try assembler.assemble(
            messages: [makeMessage(id: "m1", role: .user, content: "Hi", offset: 0)],
            toolCalls: [],
            checkpoint: nil,
            model: native
        )
        func mentionsWebSearch(_ message: LLMMessage) -> Bool {
            message.content.contains {
                if case .text(let body) = $0 { return body.contains("## Web search") }
                return false
            }
        }
        #expect(assembly.messages.contains { $0.role == .system && mentionsWebSearch($0) })
        let plainAssembly = try assembler.assemble(
            messages: [makeMessage(id: "m1", role: .user, content: "Hi", offset: 0)],
            toolCalls: [],
            checkpoint: nil,
            model: makeModel()
        )
        #expect(!plainAssembly.messages.contains(where: mentionsWebSearch))
    }

    @Test func assistantSourcesWithProviderEchoProjectAsLeadingSearchResultBlock() throws {
        // Anthropic citations need their encrypted echo before assistant text on replay.
        let assembler = ContextAssembler()
        let cited = SourceCitation(
            id: "c1",
            title: "NASA",
            url: URL(string: "https://nasa.gov/mars")!,
            snippet: "ice",
            providerEcho: ProviderEcho(kind: "anthropic.web_search", encryptedContent: "ENC", encryptedIndex: "IDX")
        )
        let assistant = MessageRecord(
            id: "a1",
            conversationId: "conv-1",
            role: .assistant,
            content: "Found ice.",
            createdAt: baseDate,
            attachmentsJSON: MessageRecord.encode(MessageAttachments(sources: [cited]))
        )

        let assembly = try assembler.assemble(
            messages: [assistant], toolCalls: [], checkpoint: nil, model: makeModel()
        )
        let assistantMessage = try #require(assembly.messages.first { $0.role == .assistant })
        #expect(assistantMessage.content.count == 2)
        guard case .searchResult(let sources) = assistantMessage.content[0] else {
            Issue.record("expected a leading .searchResult block")
            return
        }
        #expect(sources.first?.providerEcho?.encryptedContent == "ENC")
        guard case .text(let text) = assistantMessage.content[1] else {
            Issue.record("expected a trailing .text block")
            return
        }
        #expect(text == "Found ice.")
    }

    @Test func assistantSourcesWithoutProviderEchoDoNotProjectSearchResult() throws {
        let assembler = ContextAssembler()
        let foreign = SourceCitation(id: "c1", title: "T", url: URL(string: "https://example.com/a")!)
        let assistant = MessageRecord(
            id: "a1",
            conversationId: "conv-1",
            role: .assistant,
            content: "answer",
            createdAt: baseDate,
            attachmentsJSON: MessageRecord.encode(MessageAttachments(sources: [foreign]))
        )

        let assembly = try assembler.assemble(
            messages: [assistant], toolCalls: [], checkpoint: nil, model: makeModel()
        )
        let assistantMessage = try #require(assembly.messages.first { $0.role == .assistant })
        #expect(assistantMessage.content.count == 1)
        guard case .text = assistantMessage.content[0] else {
            Issue.record("expected only a .text block")
            return
        }
    }

    @Test func liveCheckpointPrependsSummaryAndDropsCoveredMessages() throws {
        let assembler = ContextAssembler()
        let messages: [MessageRecord] = [
            makeMessage(id: "m1", role: .user, content: "old 1", offset: 0),
            makeMessage(id: "m2", role: .assistant, content: "old 2", offset: 1),
            makeMessage(id: "m3", role: .user, content: "old 3", offset: 2),
            makeMessage(id: "m4", role: .assistant, content: "fresh 1", offset: 3),
            makeMessage(id: "m5", role: .user, content: "fresh 2", offset: 4),
        ]
        let checkpoint = CompactionCheckpointRecord(
            id: "ck-1",
            conversationId: "conv-1",
            uptoMessageId: "m3",
            summary: "Earlier they greeted each other and asked questions.",
            tokensBefore: 100,
            tokensAfter: 12,
            createdAt: baseDate.addingTimeInterval(2.5),
            isLive: true
        )

        let assembly = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: checkpoint,
            model: makeModel()
        )

        #expect(assembly.messages.count == 3)
        #expect(assembly.messages[0].role == .system)
        if case .text(let body) = assembly.messages[0].content.first {
            #expect(body.contains("Earlier they greeted each other"))
        } else {
            Issue.record("expected first prompt block to be .text(summary), got \(assembly.messages[0].content)")
        }
        #expect(assembly.messages[1].role == .assistant)
        #expect(assembly.messages[2].role == .user)
    }

    @Test func unknownCheckpointMessageIDFallsBackToFullHistory() throws {
        let assembler = ContextAssembler()
        let messages: [MessageRecord] = [
            makeMessage(id: "m1", role: .user, content: "Hi", offset: 0),
            makeMessage(id: "m2", role: .assistant, content: "Hello", offset: 1),
        ]
        // A deleted checkpoint boundary must not silently discard surviving context.
        let checkpoint = CompactionCheckpointRecord(
            id: "ck-stale",
            conversationId: "conv-1",
            uptoMessageId: "m-vanished",
            summary: "Summary of vanished history.",
            tokensBefore: 50,
            tokensAfter: 10,
            createdAt: baseDate,
            isLive: true
        )

        let assembly = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: checkpoint,
            model: makeModel()
        )

        #expect(assembly.messages.count == 3)
        #expect(assembly.messages[0].role == .system)
        #expect(assembly.messages[1].role == .user)
        #expect(assembly.messages[2].role == .assistant)
    }

    @Test func overThresholdClassificationIncludesExactBoundary() {
        for threshold in [0.5, 0.75, 0.9] {
            let boundary = Int(threshold * 100)
            let below = ContextAssembly(messages: [], totalTokens: boundary - 1, maxTokens: 100)
            let exact = ContextAssembly(messages: [], totalTokens: boundary, maxTokens: 100)
            let above = ContextAssembly(messages: [], totalTokens: boundary + 1, maxTokens: 100)
            #expect(!below.isOverThreshold(threshold))
            #expect(exact.isOverThreshold(threshold))
            #expect(above.isOverThreshold(threshold))
        }
    }

    @Test func ratioIsZeroWhenMaxTokensInvalid() throws {
        let assembler = ContextAssembler()
        let messages = [makeMessage(id: "m1", role: .user, content: "Hi", offset: 0)]
        let assembly = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: nil,
            model: makeModel(maxContextTokens: 0)
        )
        #expect(assembly.ratio == 0)
        #expect(assembly.isOverThreshold(0.5) == false)
    }

    @Test func leadingSystemRowsArePreservedAcrossCheckpoint() throws {
        let assembler = ContextAssembler()
        let messages: [MessageRecord] = [
            makeMessage(id: "sys-1", role: .system, content: "You are concise.", offset: 0),
            makeMessage(id: "m1", role: .user, content: "old 1", offset: 1),
            makeMessage(id: "m2", role: .assistant, content: "old 2", offset: 2),
            makeMessage(id: "m3", role: .user, content: "old 3", offset: 3),
            makeMessage(id: "m4", role: .assistant, content: "fresh 1", offset: 4),
        ]
        let checkpoint = CompactionCheckpointRecord(
            id: "ck-with-sys",
            conversationId: "conv-1",
            uptoMessageId: "m3",
            summary: "Summary of greetings.",
            tokensBefore: 80,
            tokensAfter: 8,
            createdAt: baseDate,
            isLive: true
        )

        let assembly = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: checkpoint,
            model: makeModel()
        )

        #expect(assembly.messages.count == 3)
        #expect(assembly.messages[0].role == .system)
        if case .text(let body) = assembly.messages[0].content.first {
            #expect(body == "You are concise.")
        } else {
            Issue.record("expected first message to be the original system row, got \(assembly.messages[0].content)")
        }
        #expect(assembly.messages[1].role == .system)
        if case .text(let body) = assembly.messages[1].content.first {
            #expect(body.contains("Summary of greetings."))
        } else {
            Issue.record("expected second message to be the synthetic summary, got \(assembly.messages[1].content)")
        }
        #expect(assembly.messages[2].role == .assistant)
    }

    @Test func emptyMessagesReturnsEmptyPrompt() throws {
        let assembler = ContextAssembler()
        let assembly = try assembler.assemble(
            messages: [],
            toolCalls: [],
            checkpoint: nil,
            model: makeModel()
        )
        #expect(assembly.messages.isEmpty)
        #expect(assembly.totalTokens == 0)
        #expect(assembly.isOverThreshold(0.0) == true)
    }

    // MARK: - Leading system block (chat briefing + applets + personalization)

    @Test func userPersonalizationOnlyRendersUnderHeader() throws {
        let assembler = ContextAssembler()
        let messages: [MessageRecord] = [
            makeMessage(id: "m1", role: .user, content: "Hi", offset: 0),
        ]

        let assembly = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: nil,
            model: makeModel(),
            userPersonalization: "Be concise."
        )

        #expect(assembly.messages.count == 2)
        #expect(assembly.messages[0].role == .system)
        if case .text(let body) = assembly.messages[0].content.first {
            #expect(body.contains("## User personalization"))
            #expect(body.contains("Be concise."))
        } else {
            Issue.record("expected leading .system block, got \(assembly.messages[0].content)")
        }
        #expect(assembly.messages[1].role == .user)
    }

    @Test func emptyOrWhitespaceLeadingInputsInjectNoBlock() throws {
        let assembler = ContextAssembler()
        let messages: [MessageRecord] = [
            makeMessage(id: "m1", role: .user, content: "Hi", offset: 0),
        ]

        for chat in ["", "  "] {
            for personalization in ["", "\n\t\n", "   "] {
                let assembly = try assembler.assemble(
                    messages: messages,
                    toolCalls: [],
                    checkpoint: nil,
                    model: makeModel(),
                    chatBriefing: chat,
                    appletBriefings: [],
                    userPersonalization: personalization
                )
                #expect(
                    assembly.messages.count == 1,
                    "expected no leading block for chat=\(chat.debugDescription) personalization=\(personalization.debugDescription)"
                )
                #expect(assembly.messages[0].role == .user)
            }
        }
    }

    @Test func leadingBlockTrimsEachSection() throws {
        let assembler = ContextAssembler()
        let messages: [MessageRecord] = [
            makeMessage(id: "m1", role: .user, content: "Hi", offset: 0),
        ]
        let assembly = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: nil,
            model: makeModel(),
            chatBriefing: "  trimmed chat  ",
            userPersonalization: "  trimmed me  "
        )
        guard case .text(let body) = assembly.messages[0].content.first else {
            Issue.record("missing leading block")
            return
        }
        #expect(body.contains("## Chat assistant\n\ntrimmed chat"))
        #expect(body.contains("## User personalization\n\ntrimmed me"))
    }

    @Test func chatBriefingThenAppletsThenPersonalization() throws {
        let assembler = ContextAssembler()
        let messages: [MessageRecord] = [
            makeMessage(id: "m1", role: .user, content: "Hi", offset: 0),
        ]
        let briefings = [
            AppletBriefing(label: "Bible applet", body: "Quote verbatim."),
            AppletBriefing(label: "Todo applet", body: "Parse natural-language dates."),
        ]
        let assembly = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: nil,
            model: makeModel(),
            chatBriefing: "Be concise.",
            appletBriefings: briefings,
            userPersonalization: "I prefer haiku."
        )

        guard case .text(let body) = assembly.messages[0].content.first else {
            Issue.record("missing leading block")
            return
        }
        let chatIdx = body.range(of: "## Chat assistant")!.lowerBound
        let bibleIdx = body.range(of: "## Bible applet")!.lowerBound
        let todoIdx = body.range(of: "## Todo applet")!.lowerBound
        let personalizationIdx = body.range(of: "## User personalization")!.lowerBound
        #expect(chatIdx < bibleIdx)
        #expect(bibleIdx < todoIdx)
        #expect(todoIdx < personalizationIdx)
        #expect(body.contains("Be concise."))
        #expect(body.contains("Quote verbatim."))
        #expect(body.contains("Parse natural-language dates."))
        #expect(body.contains("I prefer haiku."))
    }

    @Test func emptyAppletBriefingBodiesAreDropped() throws {
        let assembler = ContextAssembler()
        let messages: [MessageRecord] = [
            makeMessage(id: "m1", role: .user, content: "Hi", offset: 0),
        ]
        let briefings = [
            AppletBriefing(label: "Bible applet", body: "Quote verbatim."),
            AppletBriefing(label: "Empty applet", body: "   \n  "),
        ]
        let assembly = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: nil,
            model: makeModel(),
            chatBriefing: "Be concise.",
            appletBriefings: briefings
        )

        guard case .text(let body) = assembly.messages[0].content.first else {
            Issue.record("missing leading block")
            return
        }
        #expect(body.contains("## Bible applet"))
        #expect(!body.contains("## Empty applet"))
    }

    @Test func leadingBlockPrecedesCheckpointSummary() throws {
        let assembler = ContextAssembler()
        let messages: [MessageRecord] = [
            makeMessage(id: "m1", role: .user, content: "old 1", offset: 0),
            makeMessage(id: "m2", role: .assistant, content: "old 2", offset: 1),
            makeMessage(id: "m3", role: .user, content: "fresh", offset: 2),
        ]
        let checkpoint = CompactionCheckpointRecord(
            id: "ck-1",
            conversationId: "conv-1",
            uptoMessageId: "m2",
            summary: "Earlier they exchanged greetings.",
            tokensBefore: 100,
            tokensAfter: 12,
            createdAt: baseDate.addingTimeInterval(1.5),
            isLive: true
        )

        let assembly = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: checkpoint,
            model: makeModel(),
            userPersonalization: "Always answer in haiku."
        )

        #expect(assembly.messages.count == 3)
        #expect(assembly.messages[0].role == .system)
        if case .text(let body) = assembly.messages[0].content.first {
            #expect(body.contains("## User personalization"))
            #expect(body.contains("Always answer in haiku."))
        } else {
            Issue.record("expected leading block at [0], got \(assembly.messages[0].content)")
        }
        #expect(assembly.messages[1].role == .system)
        if case .text(let body) = assembly.messages[1].content.first {
            #expect(body.contains("Earlier they exchanged greetings."))
        } else {
            Issue.record("expected checkpoint summary at [1], got \(assembly.messages[1].content)")
        }
        #expect(assembly.messages[2].role == .user)
    }

    @Test func leadingBlockPrecedesHistoricalSystemRowAndCheckpoint() throws {
        let assembler = ContextAssembler()
        let messages: [MessageRecord] = [
            makeMessage(id: "sys-1", role: .system, content: "You are concise.", offset: 0),
            makeMessage(id: "m1", role: .user, content: "old", offset: 1),
            makeMessage(id: "m2", role: .assistant, content: "older", offset: 2),
            makeMessage(id: "m3", role: .user, content: "fresh", offset: 3),
        ]
        let checkpoint = CompactionCheckpointRecord(
            id: "ck-with-sys",
            conversationId: "conv-1",
            uptoMessageId: "m2",
            summary: "Summary of greetings.",
            tokensBefore: 80,
            tokensAfter: 8,
            createdAt: baseDate,
            isLive: true
        )

        let assembly = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: checkpoint,
            model: makeModel(),
            userPersonalization: "Always answer in haiku."
        )

        #expect(assembly.messages.count == 4)
        #expect(assembly.messages[0].role == .system)
        if case .text(let body) = assembly.messages[0].content.first {
            #expect(body.contains("Always answer in haiku."))
        }
        #expect(assembly.messages[1].role == .system)
        if case .text(let body) = assembly.messages[1].content.first {
            #expect(body == "You are concise.")
        }
        #expect(assembly.messages[2].role == .system)
        #expect(assembly.messages[3].role == .user)
    }

    @Test func leadingBlockTokenCountIncludedInTotal() throws {
        let assembler = ContextAssembler()
        let messages: [MessageRecord] = [
            makeMessage(id: "m1", role: .user, content: "Hi", offset: 0),
        ]
        let bare = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: nil,
            model: makeModel()
        )
        let withBlock = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: nil,
            model: makeModel(),
            chatBriefing: "You are a verbose assistant who loves long answers."
        )
        #expect(withBlock.totalTokens > bare.totalTokens)
    }

    // MARK: - Memories block

    @Test func memoriesBlockInjectedAfterLeadingSystemBlock() throws {
        // Stable instructions lead the cacheable prefix; tool-written memories change between turns.
        let assembler = ContextAssembler()
        let messages: [MessageRecord] = [
            makeMessage(id: "m1", role: .user, content: "Hi", offset: 0),
        ]

        let assembly = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: nil,
            model: makeModel(),
            userPersonalization: "Always answer in haiku.",
            memories: [
                makeMemoryEntry(id: "mem-1", text: "Prefers metric units."),
                makeMemoryEntry(id: "mem-2", text: "Vegetarian."),
            ]
        )

        #expect(assembly.messages.count == 3)
        #expect(assembly.messages[0].role == .system)
        if case .text(let body) = assembly.messages[0].content.first {
            #expect(body.contains("## User personalization"))
            #expect(body.contains("Always answer in haiku."))
        }
        #expect(assembly.messages[1].role == .system)
        if case .text(let body) = assembly.messages[1].content.first {
            #expect(body.contains("What I remember about you"))
            #expect(body.contains("- [mem-1] Prefers metric units."))
            #expect(body.contains("- [mem-2] Vegetarian."))
        } else {
            Issue.record("expected memories block at [1], got \(assembly.messages[1].content)")
        }
        #expect(assembly.messages[2].role == .user)
    }

    @Test func leadingAndWebSearchBlocksAreTaggedStablePrefix() throws {
        let assembler = ContextAssembler()
        let native = LLMModel(
            id: "native", displayName: "Native", maxContextTokens: 1_000, searchBackend: "native"
        )
        let assembly = try assembler.assemble(
            messages: [makeMessage(id: "m1", role: .user, content: "Hi", offset: 0)],
            toolCalls: [],
            checkpoint: nil,
            model: native,
            chatBriefing: "Be concise.",
            memories: [makeMemoryEntry(id: "mem-1", text: "Prefers metric units.")]
        )
        #expect(assembly.messages.count == 4)
        #expect(assembly.messages[0].cacheHint == .stablePrefix)   // briefing
        #expect(assembly.messages[1].cacheHint == .stablePrefix)   // web-search
        #expect(assembly.messages[2].cacheHint == .volatile)       // memories
        #expect(assembly.messages[3].cacheHint == .volatile)       // history
    }

    @Test func checkpointAndHistoricalSystemRowsStayVolatile() throws {
        let assembler = ContextAssembler()
        let messages: [MessageRecord] = [
            makeMessage(id: "s1", role: .system, content: "Original system prompt.", offset: 0),
            makeMessage(id: "m1", role: .user, content: "old", offset: 1),
            makeMessage(id: "m2", role: .user, content: "new", offset: 2),
        ]
        let checkpoint = CompactionCheckpointRecord(
            id: "ck1", conversationId: "c1", uptoMessageId: "m1",
            summary: "Earlier discussion.", tokensBefore: 100, tokensAfter: 10,
            createdAt: Date(timeIntervalSince1970: 1_700_000_100), isLive: true
        )
        let assembly = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: checkpoint,
            model: makeModel(),
            chatBriefing: "Be concise."
        )
        #expect(assembly.messages[0].cacheHint == .stablePrefix)
        for message in assembly.messages.dropFirst() {
            #expect(message.cacheHint == .volatile)
        }
    }

    @Test func memoriesBlockSurfacesIdsAlongsideText() throws {
        // Memory IDs let the model update or forget entries saved in earlier sessions.
        let assembler = ContextAssembler()
        let messages: [MessageRecord] = [
            makeMessage(id: "m1", role: .user, content: "Hi", offset: 0),
        ]

        let assembly = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: nil,
            model: makeModel(),
            memories: [
                makeMemoryEntry(id: "A1B2C3D4", text: "Vegetarian."),
            ]
        )

        guard case .text(let body) = assembly.messages[0].content.first else {
            Issue.record("missing memories block")
            return
        }
        #expect(body.contains("- [A1B2C3D4] Vegetarian."))
    }

    @Test func emptyMemoriesArrayInjectsNothing() throws {
        let assembler = ContextAssembler()
        let messages: [MessageRecord] = [
            makeMessage(id: "m1", role: .user, content: "Hi", offset: 0),
        ]

        let assembly = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: nil,
            model: makeModel(),
            memories: []
        )

        #expect(assembly.messages.count == 1)
        #expect(assembly.messages[0].role == .user)
    }

    @Test func whitespaceOnlyMemoriesAreFiltered() throws {
        let assembler = ContextAssembler()
        let messages: [MessageRecord] = [
            makeMessage(id: "m1", role: .user, content: "Hi", offset: 0),
        ]

        let mixed = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: nil,
            model: makeModel(),
            memories: [
                makeMemoryEntry(id: "blank-1", text: "  "),
                makeMemoryEntry(id: "real-1", text: "Real preference."),
                makeMemoryEntry(id: "blank-2", text: "\n\n"),
            ]
        )
        if case .text(let body) = mixed.messages[0].content.first {
            #expect(body.contains("- [real-1] Real preference."))
            #expect(body.contains("[blank-1]") == false)
            #expect(body.contains("[blank-2]") == false)
        }

        let allBlank = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: nil,
            model: makeModel(),
            memories: [
                makeMemoryEntry(id: "b1", text: ""),
                makeMemoryEntry(id: "b2", text: "  "),
                makeMemoryEntry(id: "b3", text: "\n"),
            ]
        )
        #expect(allBlank.messages.count == 1)
        #expect(allBlank.messages[0].role == .user)
    }

    @Test func memoriesBlockOrderingIsStable() throws {
        let assembler = ContextAssembler()
        let messages: [MessageRecord] = [
            makeMessage(id: "m1", role: .user, content: "Hi", offset: 0),
        ]
        let inputs = [
            makeMemoryEntry(id: "id1", text: "first"),
            makeMemoryEntry(id: "id2", text: "second"),
            makeMemoryEntry(id: "id3", text: "third"),
        ]

        let assembly = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: nil,
            model: makeModel(),
            memories: inputs
        )

        guard case .text(let body) = assembly.messages[0].content.first else {
            Issue.record("missing memories block")
            return
        }
        let firstIdx = body.range(of: "first")!.lowerBound
        let secondIdx = body.range(of: "second")!.lowerBound
        let thirdIdx = body.range(of: "third")!.lowerBound
        #expect(firstIdx < secondIdx)
        #expect(secondIdx < thirdIdx)
    }

    private func makeMemoryEntry(id: String, text: String) -> MemoryEntry {
        MemoryEntry(id: id, text: text, createdAt: baseDate, updatedAt: baseDate)
    }

    // MARK: - Tool-call pairing totality

    private func makeToolCall(
        id: String,
        messageId: String,
        toolName: String = "test.tool",
        status: ToolCallStatus = .executing
    ) -> ToolCallRecord {
        ToolCallRecord(
            id: id,
            messageId: messageId,
            conversationId: "conv-1",
            toolName: toolName,
            parameters: "{}",
            result: nil,
            status: status,
            createdAt: baseDate,
            completedAt: nil,
            signature: nil
        )
    }

    /// Anthropic tool continuations must lead with the original signed thinking block.
    @Test func assistantThinkingProjectsFirstWithSignature() throws {
        let assembler = ContextAssembler()
        var assistant = makeMessage(id: "m2", role: .assistant, content: "checking", offset: 1)
        assistant.thinkingContent = "I should call the tool."
        assistant.thinkingSignature = "sig-9"
        assistant.thinkingModelId = "test-model"
        let messages = [
            makeMessage(id: "m1", role: .user, content: "run the tool", offset: 0),
            assistant,
            makeMessage(id: "m3", role: .tool, content: "done", offset: 2, toolCallId: "tc-1"),
        ]
        let calls = [makeToolCall(id: "tc-1", messageId: "m2", status: .success)]

        let assembly = try assembler.assemble(
            messages: messages, toolCalls: calls, checkpoint: nil, model: makeModel()
        )

        let assistantMessage = try #require(assembly.messages.first { $0.role == .assistant })
        guard case .thinking(let content, let signature) = assistantMessage.content.first else {
            Issue.record("expected .thinking as the first block, got \(String(describing: assistantMessage.content.first))")
            return
        }
        #expect(content == "I should call the tool.")
        #expect(signature == "sig-9")
        guard case .text("checking") = assistantMessage.content.dropFirst().first else {
            Issue.record("expected .text after the thinking block")
            return
        }
        let hasToolUse = assistantMessage.content.contains { block in
            if case .toolUse("tc-1", _, _, _) = block { return true }
            return false
        }
        #expect(hasToolUse)
    }

    /// Foreign-model signatures would be rejected. Dropping them lets the adapter
    /// disable thinking for an unreplayable continuation.
    @Test func thinkingSignatureFromAnotherModelIsNotReplayed() throws {
        let assembler = ContextAssembler()
        var assistant = makeMessage(id: "m2", role: .assistant, content: "checking", offset: 1)
        assistant.thinkingContent = "reasoning from the old model"
        assistant.thinkingSignature = "sig-from-model-A"
        assistant.thinkingModelId = "model-A"
        let messages = [
            makeMessage(id: "m1", role: .user, content: "hi", offset: 0),
            assistant,
        ]

        let assembly = try assembler.assemble(
            messages: messages, toolCalls: [], checkpoint: nil, model: makeModel()
        )

        let assistantMessage = try #require(assembly.messages.first { $0.role == .assistant })
        guard case .thinking(let content, let signature) = assistantMessage.content.first else {
            Issue.record("expected .thinking block, got \(String(describing: assistantMessage.content.first))")
            return
        }
        #expect(content == "reasoning from the old model")
        #expect(signature == nil)
    }

    /// Missing results need adjacent synthetic replies or strict providers reject
    /// every subsequent turn against the unanswered call.
    @Test func orphanedToolUseProjectsSynthesizedResult() throws {
        let assembler = ContextAssembler()
        let messages = [
            makeMessage(id: "m1", role: .user, content: "run the tool", offset: 0),
            makeMessage(id: "m2", role: .assistant, content: "on it", offset: 1),
            makeMessage(id: "m3", role: .user, content: "did it work?", offset: 2),
        ]
        let calls = [makeToolCall(id: "tc-1", messageId: "m2")]

        let assembly = try assembler.assemble(
            messages: messages, toolCalls: calls, checkpoint: nil, model: makeModel()
        )

        let toolMessages = assembly.messages.filter { $0.role == .tool }
        #expect(toolMessages.count == 1)
        guard case .toolResult(let useID, _, let isError) = toolMessages.first?.content.first else {
            Issue.record("expected a synthesized toolResult block")
            return
        }
        #expect(useID == "tc-1")
        #expect(isError == true)
        let assistantIndex = try #require(assembly.messages.firstIndex { $0.role == .assistant })
        let resultIndex = try #require(assembly.messages.firstIndex { $0.role == .tool })
        let trailingUserIndex = try #require(assembly.messages.lastIndex { $0.role == .user })
        #expect(resultIndex == assistantIndex + 1)
        #expect(resultIndex < trailingUserIndex)
    }

    /// An earlier result cannot pair with a later call. Drop it without suppressing
    /// synthesis beside the actual issuer.
    @Test func resultRowBeforeItsToolUseIsDroppedAndSynthesisStillFires() throws {
        let assembler = ContextAssembler()
        let messages = [
            makeMessage(id: "m1", role: .tool, content: "early result", offset: 0, toolCallId: "tc-1"),
            makeMessage(id: "m2", role: .user, content: "run it", offset: 1),
            makeMessage(id: "m3", role: .assistant, content: "running", offset: 2),
        ]
        let calls = [makeToolCall(id: "tc-1", messageId: "m3")]

        let assembly = try assembler.assemble(
            messages: messages, toolCalls: calls, checkpoint: nil, model: makeModel()
        )

        let toolMessages = assembly.messages.filter { $0.role == .tool }
        #expect(toolMessages.count == 1)
        guard case .toolResult("tc-1", let content, true) = toolMessages.first?.content.first else {
            Issue.record("expected the synthesized error toolResult, not the early row")
            return
        }
        #expect(content != "early result")
        let assistantIndex = try #require(assembly.messages.firstIndex { $0.role == .assistant })
        let resultIndex = try #require(assembly.messages.firstIndex { $0.role == .tool })
        #expect(resultIndex == assistantIndex + 1)
    }

    /// Older checkpoints may split a tool pair even though new cuts preserve it.
    /// Drop surviving orphan results before replay.
    @Test func checkpointCutBetweenPairDropsOrphanResultRow() throws {
        let assembler = ContextAssembler()
        let messages = [
            makeMessage(id: "m1", role: .user, content: "run the tool", offset: 0),
            makeMessage(id: "m2", role: .assistant, content: "running", offset: 1),
            makeMessage(id: "m3", role: .tool, content: "stranded result", offset: 2, toolCallId: "tc-1"),
            makeMessage(id: "m4", role: .user, content: "next question", offset: 3),
        ]
        let calls = [makeToolCall(id: "tc-1", messageId: "m2", status: .success)]
        let checkpoint = CompactionCheckpointRecord(
            id: "cp-1",
            conversationId: "conv-1",
            uptoMessageId: "m2",
            summary: "User asked to run the tool; the assistant ran it.",
            tokensBefore: 100,
            tokensAfter: 10,
            createdAt: baseDate,
            isLive: true
        )

        let assembly = try assembler.assemble(
            messages: messages, toolCalls: calls, checkpoint: checkpoint, model: makeModel()
        )

        for message in assembly.messages {
            #expect(message.role != .tool)
            for block in message.content {
                if case .toolUse = block { Issue.record("unexpected toolUse past checkpoint") }
                if case .toolResult = block { Issue.record("unexpected orphan toolResult past checkpoint") }
            }
        }
        #expect(assembly.messages.contains { $0.role == .user })
    }

    @Test func partiallyResolvedBatchSynthesizesOnlyMissingResults() throws {
        let assembler = ContextAssembler()
        let messages = [
            makeMessage(id: "m1", role: .user, content: "run both tools", offset: 0),
            makeMessage(id: "m2", role: .assistant, content: "running", offset: 1),
            makeMessage(id: "m3", role: .tool, content: "first result", offset: 2, toolCallId: "tc-1"),
        ]
        let calls = [
            makeToolCall(id: "tc-1", messageId: "m2", status: .success),
            makeToolCall(id: "tc-2", messageId: "m2"),
        ]

        let assembly = try assembler.assemble(
            messages: messages, toolCalls: calls, checkpoint: nil, model: makeModel()
        )

        var seenResultIDs: [String] = []
        for message in assembly.messages where message.role == .tool {
            for block in message.content {
                if case .toolResult(let useID, _, _) = block {
                    seenResultIDs.append(useID)
                }
            }
        }
        #expect(seenResultIDs.sorted() == ["tc-1", "tc-2"])
        var foundRealResult = false
        for message in assembly.messages {
            for block in message.content {
                if case .toolResult("tc-1", let content, _) = block, content == "first result" {
                    foundRealResult = true
                }
            }
        }
        #expect(foundRealResult)
    }

    @Test func orphanedToolResultRowIsDropped() throws {
        let assembler = ContextAssembler()
        let messages = [
            makeMessage(id: "m1", role: .tool, content: "stranded result", offset: 0, toolCallId: "tc-ghost"),
            makeMessage(id: "m2", role: .user, content: "hello again", offset: 1),
        ]
        let calls = [makeToolCall(id: "tc-ghost", messageId: "m-dropped", status: .success)]

        let assembly = try assembler.assemble(
            messages: messages, toolCalls: calls, checkpoint: nil, model: makeModel()
        )

        var sawToolMessage = false
        var sawUserMessage = false
        for message in assembly.messages {
            if message.role == .tool { sawToolMessage = true }
            if message.role == .user { sawUserMessage = true }
        }
        #expect(!sawToolMessage)
        #expect(sawUserMessage)
    }
}
