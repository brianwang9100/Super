import Core
import Foundation
import Testing

@testable import Chat

/// Tests for `ContextAssembler` — projects rows + checkpoint into the
/// `[LLMMessage]` shipped to the provider, and reports whether the
/// resulting prompt is over a configurable threshold of the model's
/// context window.
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

    private func makeModel(maxContextTokens: Int = 1_000) -> LLMModel {
        LLMModel(
            id: "test-model",
            displayName: "Test",
            supportsThinking: false,
            supportsTools: true,
            maxContextTokens: maxContextTokens
        )
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
        // ~80 chars total → ~20 tokens via chars/4. Model max 100 → 20%
        // — safely under any sensible threshold.
        let lightMessages: [MessageRecord] = [
            makeMessage(id: "m1", role: .user, content: String(repeating: "a", count: 80), offset: 0),
        ]
        let lightAssembly = try assembler.assemble(
            messages: lightMessages,
            toolCalls: [],
            checkpoint: nil,
            model: makeModel(maxContextTokens: 100)
        )
        #expect(lightAssembly.isOverThreshold(0.5) == false)
        #expect(lightAssembly.isOverThreshold(0.75) == false)

        // ~400 chars → ~100 tokens vs. 100 max → ratio 1.0.
        let heavyMessages: [MessageRecord] = [
            makeMessage(id: "m1", role: .user, content: String(repeating: "a", count: 400), offset: 0),
        ]
        let heavyAssembly = try assembler.assemble(
            messages: heavyMessages,
            toolCalls: [],
            checkpoint: nil,
            model: makeModel(maxContextTokens: 100)
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
        // M9 will write the user's system prompt as a `.system`
        // `MessageRecord` at conversation start. Compaction must not
        // erase it — the assembler re-emits any leading `.system` rows
        // covered by the checkpoint in front of the synthetic summary.
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

    @Test func systemPromptInjectedAtTopWhenNonEmpty() throws {
        let assembler = ContextAssembler()
        let messages: [MessageRecord] = [
            makeMessage(id: "m1", role: .user, content: "Hi", offset: 0),
            makeMessage(id: "m2", role: .assistant, content: "Hello", offset: 1),
        ]

        let assembly = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: nil,
            systemPrompt: "You are concise.",
            model: makeModel()
        )

        #expect(assembly.messages.count == 3)
        #expect(assembly.messages[0].role == .system)
        if case .text(let body) = assembly.messages[0].content.first {
            #expect(body == "You are concise.")
        } else {
            Issue.record("expected settings prompt at [0], got \(assembly.messages[0].content)")
        }
        #expect(assembly.messages[1].role == .user)
        #expect(assembly.messages[2].role == .assistant)
    }

    @Test func systemPromptIsTrimmedAndSkippedWhenWhitespaceOnly() throws {
        let assembler = ContextAssembler()
        let messages: [MessageRecord] = [
            makeMessage(id: "m1", role: .user, content: "Hi", offset: 0),
        ]

        for prompt in ["", "   ", "\n\t\n"] {
            let assembly = try assembler.assemble(
                messages: messages,
                toolCalls: [],
                checkpoint: nil,
                systemPrompt: prompt,
                model: makeModel()
            )
            #expect(
                assembly.messages.count == 1,
                "expected no system injection for whitespace prompt \(prompt.debugDescription)"
            )
            #expect(assembly.messages[0].role == .user)
        }

        // Trimming: leading/trailing whitespace stripped, interior preserved.
        let assembly = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: nil,
            systemPrompt: "  haiku\nplease  ",
            model: makeModel()
        )
        #expect(assembly.messages.count == 2)
        if case .text(let body) = assembly.messages[0].content.first {
            #expect(body == "haiku\nplease")
        } else {
            Issue.record("expected trimmed prompt, got \(assembly.messages[0].content)")
        }
    }

    @Test func systemPromptPrecedesCheckpointSummary() throws {
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
            systemPrompt: "Always answer in haiku.",
            model: makeModel()
        )

        // [0] settings prompt, [1] checkpoint summary, [2] m3
        #expect(assembly.messages.count == 3)
        #expect(assembly.messages[0].role == .system)
        if case .text(let body) = assembly.messages[0].content.first {
            #expect(body == "Always answer in haiku.")
        } else {
            Issue.record("expected settings prompt at [0], got \(assembly.messages[0].content)")
        }
        #expect(assembly.messages[1].role == .system)
        if case .text(let body) = assembly.messages[1].content.first {
            #expect(body.contains("Earlier they exchanged greetings."))
        } else {
            Issue.record("expected checkpoint summary at [1], got \(assembly.messages[1].content)")
        }
        #expect(assembly.messages[2].role == .user)
    }

    @Test func systemPromptPrecedesHistoricalSystemRowAndCheckpoint() throws {
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
            systemPrompt: "Always answer in haiku.",
            model: makeModel()
        )

        // [0] settings, [1] historical .system, [2] checkpoint, [3] m3
        #expect(assembly.messages.count == 4)
        #expect(assembly.messages[0].role == .system)
        if case .text(let body) = assembly.messages[0].content.first {
            #expect(body == "Always answer in haiku.")
        }
        #expect(assembly.messages[1].role == .system)
        if case .text(let body) = assembly.messages[1].content.first {
            #expect(body == "You are concise.")
        }
        #expect(assembly.messages[2].role == .system) // checkpoint summary
        #expect(assembly.messages[3].role == .user)
    }

    @Test func systemPromptTokenCountIncludedInTotal() throws {
        let assembler = ContextAssembler()
        let messages: [MessageRecord] = [
            makeMessage(id: "m1", role: .user, content: "Hi", offset: 0),
        ]
        let bare = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: nil,
            systemPrompt: "",
            model: makeModel()
        )
        let withPrompt = try assembler.assemble(
            messages: messages,
            toolCalls: [],
            checkpoint: nil,
            systemPrompt: "You are a verbose assistant who loves long answers.",
            model: makeModel()
        )
        #expect(withPrompt.totalTokens > bare.totalTokens)
    }
}
