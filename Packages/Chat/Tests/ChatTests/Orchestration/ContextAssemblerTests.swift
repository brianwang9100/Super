import Core
import Foundation
import Testing

@testable import Chat

/// Tests for `ContextAssembler` — projects rows + checkpoint into the
/// `[LLMMessage]` shipped to the provider, builds the leading
/// concatenated `.system` block (Chat briefing + applet briefings +
/// user personalization), and reports whether the resulting prompt is
/// over a configurable threshold of the model's context window.
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

    /// Defaults to a full-tier window so shape/budget tests read the raw
    /// heuristic estimate; tests of the compact-tier calibration pass an
    /// explicit small window.
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
        // The same prompt with tools advertised must cost more — the schema
        // weight is folded into the budget the compaction gates read.
        #expect(withTools.totalTokens > withoutTools.totalTokens)
    }

    @Test func toolSchemasCanTipOverThreshold() throws {
        // Regression for the AFM silent-overflow: a prompt comfortably under
        // the window with no tool counting must be pushed over once the
        // verbose tool schemas it actually ships are counted. Run on a
        // full-tier window so the raw schema weight is the only variable —
        // on the compact tier the calibration allowance would tip the
        // no-tools arm by itself (covered separately below).
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
        // The compact tier models the on-device provider: tool schemas cost
        // ~1.8× the raw heuristic (JSON-schema scaffolding + real tokenizer)
        // and the provider injects base instructions we can't read (flat
        // allowance). Full tier is the uncalibrated baseline.
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
        // The whole calibrated tool + allowance weight is fixed; only the
        // projected history is compressible.
        #expect(
            compactWithTools.fixedTokens
                == inflatedToolTokens + ContextAssembler.compactTierFixedOverheadTokens
        )
        #expect(compactWithTools.compressibleTokens == fullNoTools.totalTokens)
        #expect(fullWithTools.fixedTokens == rawToolTokens)
    }

    @Test func fixedTokensIncludeAssemblerInjectedSystemBlocks() throws {
        // Briefings (and the other assembler-injected blocks) survive every
        // compaction checkpoint, so they count as fixed: the compressible
        // remainder must be just the projected history.
        let assembler = ContextAssembler()
        let messages = [makeMessage(id: "m1", role: .user, content: "Hi", offset: 0)]
        let assembly = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: nil,
            model: makeModel(maxContextTokens: 4_096),
            chatBriefing: String(repeating: "Be concise. ", count: 50)
        )
        // "Hi" estimates to 1 token; everything else (leading block +
        // compact-tier allowance) is floor.
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
        // Native-search model gets the guidance block; non-native gets nil so
        // its prompt is byte-identical to before this feature.
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
        // A leading `.system` row carries the web-search guidance; a
        // non-native model never adds one.
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
        // The encrypted round-trip: a prior assistant turn's stored citations
        // (carrying an Anthropic `providerEcho`) reattach as a `.searchResult`
        // block placed before the text, so the Anthropic adapter can replay the
        // encrypted echo on the next turn.
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
        // Citations lacking an echo (OpenAI/Gemini/standalone) carry nothing to
        // round-trip, so no `.searchResult` block is emitted — only the text.
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

        // Prompt: synthetic system summary + the two messages after m3.
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
        // Checkpoint points at a message that isn't in the list (e.g.
        // post-deletion). Assembler keeps every message rather than
        // silently dropping the tail — losing context is worse than
        // ignoring a stale checkpoint.
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

        // Synthetic system summary + both original messages.
        #expect(assembly.messages.count == 3)
        #expect(assembly.messages[0].role == .system)
        #expect(assembly.messages[1].role == .user)
        #expect(assembly.messages[2].role == .assistant)
    }

    @Test func overThresholdClassificationFiresAtConfiguredFraction() throws {
        let assembler = ContextAssembler()
        // ~80 chars total → ~20 tokens via chars/4. Model max 100k (full
        // tier — raw meter) → far under any sensible threshold.
        let lightMessages: [MessageRecord] = [
            makeMessage(id: "m1", role: .user, content: String(repeating: "a", count: 80), offset: 0),
        ]
        let lightAssembly = try assembler.assemble(
            messages: lightMessages,
            toolCalls: [],
            checkpoint: nil,
            model: makeModel(maxContextTokens: 100_000)
        )
        #expect(lightAssembly.isOverThreshold(0.5) == false)
        #expect(lightAssembly.isOverThreshold(0.75) == false)

        // ~400k chars → ~100k tokens vs. 100k max → ratio 1.0.
        let heavyMessages: [MessageRecord] = [
            makeMessage(id: "m1", role: .user, content: String(repeating: "a", count: 400_000), offset: 0),
        ]
        let heavyAssembly = try assembler.assemble(
            messages: heavyMessages,
            toolCalls: [],
            checkpoint: nil,
            model: makeModel(maxContextTokens: 100_000)
        )
        #expect(heavyAssembly.isOverThreshold(0.5))
        #expect(heavyAssembly.isOverThreshold(0.75))
        #expect(heavyAssembly.isOverThreshold(0.9))
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
        // Misconfigured model surfaces as ratio == 0 rather than crashing,
        // suppressing auto-compaction.
        #expect(assembly.ratio == 0)
        #expect(assembly.isOverThreshold(0.5) == false)
    }

    @Test func leadingSystemRowsArePreservedAcrossCheckpoint() throws {
        // Conversations may carry a `.system` `MessageRecord` at the
        // start (e.g. an explicit per-conversation system row). Compaction
        // must not erase it — the assembler re-emits any leading
        // `.system` rows covered by the checkpoint in front of the
        // synthetic summary.
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

        // Order: original system prompt, synthetic summary, post-checkpoint.
        #expect(assembly.messages.count == 3)
        #expect(assembly.messages[0].role == .system)
        if case .text(let body) = assembly.messages[0].content.first {
            #expect(body == "You are concise.")
        } else {
            Issue.record("expected first message to be the original system row, got \(assembly.messages[0].content)")
        }
        #expect(assembly.messages[1].role == .system) // synthetic summary
        if case .text(let body) = assembly.messages[1].content.first {
            #expect(body.contains("Summary of greetings."))
        } else {
            Issue.record("expected second message to be the synthetic summary, got \(assembly.messages[1].content)")
        }
        #expect(assembly.messages[2].role == .assistant) // m4
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
        // 0 / N ≥ 0.0 is true — the strict-ge boundary makes the empty
        // case "over threshold 0.0" by definition; tests that pass a real
        // threshold (≥ a tiny epsilon) won't see this corner.
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
        // The three label classes appear in fixed order with their
        // headers, and applet briefings render in the order supplied.
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
        // The registry already skips empties before constructing the
        // briefing list, but the assembler defends in depth — a fixture
        // that hand-rolls a briefing with an empty body shouldn't render
        // a header with nothing under it.
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

        // [0] leading block, [1] checkpoint summary, [2] m3
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

        // [0] leading block, [1] historical .system, [2] checkpoint, [3] m3
        #expect(assembly.messages.count == 4)
        #expect(assembly.messages[0].role == .system)
        if case .text(let body) = assembly.messages[0].content.first {
            #expect(body.contains("Always answer in haiku."))
        }
        #expect(assembly.messages[1].role == .system)
        if case .text(let body) = assembly.messages[1].content.first {
            #expect(body == "You are concise.")
        }
        #expect(assembly.messages[2].role == .system) // checkpoint summary
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
        // Order rationale: the leading block (chat + applets +
        // personalization) is the most stable across turns, so it sits
        // at the head of the system run for the Anthropic prompt cache
        // prefix. Memories change every time the `memory` tool runs and
        // live in their own block immediately after.
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

        // [0] leading block (with personalization), [1] memories block, [2] user
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

    @Test func memoriesBlockSurfacesIdsAlongsideText() throws {
        // Regression for PR #72 round-4: the bullets must lead with
        // `[<id>]` so the LLM can call `memory(op:'update'|'forget',
        // id:...)` on entries it didn't `save` this session — without
        // the id, the descriptor's "Ids come from the surfaced memory
        // block" contract is broken on every follow-up conversation.
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
        // Bullet form `- [<id>] <text>` so a regex on the LLM side
        // can extract the id deterministically.
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
        // A mid-flight repository hiccup or a user-edited blank shouldn't
        // produce a stray empty bullet — the block should render only the
        // real entries, and the whole block should disappear when *all*
        // entries are blank.
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
            // Blank entries are dropped entirely — no bullet, no stray
            // id-only line either.
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
        // The block must reflect the caller-provided order verbatim (the
        // orchestrator sorts by createdAt before passing) — re-ordering
        // here would flicker "what I remember about you" across turns.
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

    /// An assistant `toolUse` whose result row never landed (cancel/crash
    /// mid-execution) must still project a `tool_result` — strict providers
    /// reject a history with an unanswered `tool_use` on every later turn,
    /// permanently wedging the conversation.
    @Test func orphanedToolUseProjectsSynthesizedResult() throws {
        let assembler = ContextAssembler()
        let messages = [
            makeMessage(id: "m1", role: .user, content: "run the tool", offset: 0),
            makeMessage(id: "m2", role: .assistant, content: "on it", offset: 1),
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
    }

    /// In a multi-call batch where only some calls resolved, synthesis fills
    /// exactly the gaps — the real result row is kept, not duplicated.
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
        // The real row's content survives untouched.
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

    /// A role-`.tool` row whose `tool_use` was never projected (e.g. the
    /// assistant row fell on the far side of a compaction checkpoint) must
    /// be dropped — an orphan `tool_result` is rejected by strict providers
    /// just like an unanswered `tool_use`.
    @Test func orphanedToolResultRowIsDropped() throws {
        let assembler = ContextAssembler()
        let messages = [
            makeMessage(id: "m1", role: .tool, content: "stranded result", offset: 0, toolCallId: "tc-ghost"),
            makeMessage(id: "m2", role: .user, content: "hello again", offset: 1),
        ]
        // The call record survives but points at an assistant row that is
        // not part of the projected window.
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
