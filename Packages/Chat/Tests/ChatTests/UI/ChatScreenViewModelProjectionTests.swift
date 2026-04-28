import Foundation
import Testing
@testable import Chat

/// Pure-function coverage on `ChatScreenViewModel.project(...)`. Verifies
/// that on-disk record arrays are folded into the view-model `Item`s the
/// list renders, including tool-call result inlining and compaction
/// banner placement.
@Suite("ChatScreenViewModel.project")
struct ChatScreenViewModelProjectionTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("user + assistant rows project to bubble + text")
    func userAndAssistantProject() {
        let items = ChatScreenViewModel.project(
            messages: [
                MessageRecord(id: "u1", conversationId: "c", role: .user, content: "hello", createdAt: now),
                MessageRecord(id: "a1", conversationId: "c", role: .assistant, content: "hi there", createdAt: now.addingTimeInterval(1)),
            ],
            toolCalls: [],
            checkpoint: nil
        )

        #expect(items.count == 2)
        if case .userBubble(let id, let text) = items[0] {
            #expect(id == "u1")
            #expect(text == "hello")
        } else {
            Issue.record("expected user bubble")
        }
        if case .assistantText(let id, let thinking, let durationMs, let text, let calls) = items[1] {
            #expect(id == "a1")
            #expect(thinking == nil)
            #expect(durationMs == nil)
            #expect(text == "hi there")
            #expect(calls.isEmpty)
        } else {
            Issue.record("expected assistant text")
        }
    }

    @Test("assistant thinking content + duration project onto the row")
    func thinkingContentProjects() {
        let items = ChatScreenViewModel.project(
            messages: [
                MessageRecord(
                    id: "a1",
                    conversationId: "c",
                    role: .assistant,
                    content: "the answer is 42",
                    thinkingContent: "let me think... it must be 42",
                    thinkingDurationMs: 4_200,
                    createdAt: now
                ),
            ],
            toolCalls: [],
            checkpoint: nil
        )
        #expect(items.count == 1)
        guard case .assistantText(_, let thinking, let durationMs, let text, _) = items[0] else {
            Issue.record("expected assistant row")
            return
        }
        #expect(thinking == "let me think... it must be 42")
        #expect(durationMs == 4_200)
        #expect(text == "the answer is 42")
    }

    @Test("assistant tool calls fold their result into the call view")
    func toolResultsFold() {
        let messages: [MessageRecord] = [
            MessageRecord(id: "u1", conversationId: "c", role: .user, content: "what time?", createdAt: now),
            MessageRecord(id: "a1", conversationId: "c", role: .assistant, content: "", createdAt: now.addingTimeInterval(1)),
            MessageRecord(id: "tres", conversationId: "c", role: .tool, content: "It is 3pm.", toolCallId: "tc1", createdAt: now.addingTimeInterval(2)),
        ]
        let toolCalls: [ToolCallRecord] = [
            ToolCallRecord(
                id: "tc1",
                messageId: "a1",
                conversationId: "c",
                toolName: "time.now",
                parameters: "{}",
                result: "{\"content\":\"It is 3pm.\"}",
                status: .success,
                createdAt: now.addingTimeInterval(1.5),
                completedAt: now.addingTimeInterval(2)
            ),
        ]

        let items = ChatScreenViewModel.project(messages: messages, toolCalls: toolCalls, checkpoint: nil)
        // Two visible items: the user bubble and the assistant row holding
        // the tool call. The tool result MessageRecord is folded in, not
        // rendered as a separate row.
        #expect(items.count == 2)
        guard case .assistantText(_, _, _, _, let calls) = items[1] else {
            Issue.record("expected assistant row at index 1")
            return
        }
        #expect(calls.count == 1)
        #expect(calls[0].toolName == "time.now")
        #expect(calls[0].status == .success)
        #expect(calls[0].resultText == "It is 3pm.")
    }

    @Test("compaction banner inserted after the cutoff message")
    func compactionBannerInsertion() {
        let messages: [MessageRecord] = [
            MessageRecord(id: "u1", conversationId: "c", role: .user, content: "first", createdAt: now),
            MessageRecord(id: "a1", conversationId: "c", role: .assistant, content: "earlier reply", createdAt: now.addingTimeInterval(1)),
            MessageRecord(id: "u2", conversationId: "c", role: .user, content: "second", createdAt: now.addingTimeInterval(2)),
        ]
        let checkpoint = CompactionCheckpointRecord(
            id: "cp1",
            conversationId: "c",
            uptoMessageId: "a1",
            summary: "User said hello, assistant replied.",
            tokensBefore: 10,
            tokensAfter: 4,
            createdAt: now.addingTimeInterval(1.5),
            isLive: true
        )

        let items = ChatScreenViewModel.project(messages: messages, toolCalls: [], checkpoint: checkpoint)
        // Expected layout: user, assistant, banner, user.
        #expect(items.count == 4)
        guard case .compactionBanner(_, let summary) = items[2] else {
            Issue.record("expected compaction banner at index 2")
            return
        }
        #expect(summary == "User said hello, assistant replied.")
    }

    @Test("system rows are dropped from the transcript")
    func systemRowsDropped() {
        let items = ChatScreenViewModel.project(
            messages: [
                MessageRecord(id: "s1", conversationId: "c", role: .system, content: "you are super", createdAt: now),
                MessageRecord(id: "u1", conversationId: "c", role: .user, content: "hi", createdAt: now.addingTimeInterval(1)),
            ],
            toolCalls: [],
            checkpoint: nil
        )
        #expect(items.count == 1)
        if case .userBubble = items[0] {} else { Issue.record("expected only the user bubble") }
    }

    @Test("compaction banner emits when cutoff lands on a tool row that gets dropped")
    func compactionBannerOnDroppedToolCutoff() {
        // Cutoff is the tool row, which the projection drops. The banner
        // must still appear immediately before the next renderable user
        // message — the prior heuristic compared cutoff to `items.last.id`
        // and missed this case because the tool row never made it in.
        let messages: [MessageRecord] = [
            MessageRecord(id: "u1", conversationId: "c", role: .user, content: "first", createdAt: now),
            MessageRecord(id: "a1", conversationId: "c", role: .assistant, content: "running tool", createdAt: now.addingTimeInterval(1)),
            MessageRecord(id: "tres", conversationId: "c", role: .tool, content: "tool result", toolCallId: "tc1", createdAt: now.addingTimeInterval(2)),
            MessageRecord(id: "u2", conversationId: "c", role: .user, content: "follow up", createdAt: now.addingTimeInterval(3)),
        ]
        let checkpoint = CompactionCheckpointRecord(
            id: "cp1",
            conversationId: "c",
            uptoMessageId: "tres",
            summary: "Earlier turn including a tool call.",
            tokensBefore: 20,
            tokensAfter: 6,
            createdAt: now.addingTimeInterval(2.5),
            isLive: true
        )

        let items = ChatScreenViewModel.project(messages: messages, toolCalls: [], checkpoint: checkpoint)
        // Expected layout: user, assistant, banner, user. The tool row is
        // dropped and the banner sits between it and the next user row.
        #expect(items.count == 4)
        guard case .compactionBanner(_, let summary) = items[2] else {
            Issue.record("expected compaction banner at index 2")
            return
        }
        #expect(summary == "Earlier turn including a tool call.")
        if case .userBubble(let id, _) = items[3] {
            #expect(id == "u2")
        } else {
            Issue.record("expected user bubble after the banner")
        }
    }

    @Test("compaction banner emits at the tail when cutoff is the last message")
    func compactionBannerAtTail() {
        // Cutoff is the most recent persisted message, so there's nothing
        // after it to trigger the "emit before next iteration" path.
        // The banner should still render at the tail of the transcript.
        let messages: [MessageRecord] = [
            MessageRecord(id: "u1", conversationId: "c", role: .user, content: "first", createdAt: now),
            MessageRecord(id: "a1", conversationId: "c", role: .assistant, content: "reply", createdAt: now.addingTimeInterval(1)),
        ]
        let checkpoint = CompactionCheckpointRecord(
            id: "cp1",
            conversationId: "c",
            uptoMessageId: "a1",
            summary: "All prior turns folded in.",
            tokensBefore: 30,
            tokensAfter: 8,
            createdAt: now.addingTimeInterval(1.5),
            isLive: true
        )

        let items = ChatScreenViewModel.project(messages: messages, toolCalls: [], checkpoint: checkpoint)
        #expect(items.count == 3)
        guard case .compactionBanner(_, let summary) = items[2] else {
            Issue.record("expected compaction banner at the tail")
            return
        }
        #expect(summary == "All prior turns folded in.")
    }

    @Test("running and failed tool statuses surface")
    func toolStatusMapping() {
        let messages: [MessageRecord] = [
            MessageRecord(id: "a1", conversationId: "c", role: .assistant, content: "", createdAt: now),
        ]
        let toolCalls: [ToolCallRecord] = [
            ToolCallRecord(id: "t1", messageId: "a1", conversationId: "c", toolName: "x.run", parameters: "{}", status: .pending, createdAt: now),
            ToolCallRecord(id: "t2", messageId: "a1", conversationId: "c", toolName: "x.boom", parameters: "{}", status: .failed, createdAt: now),
        ]
        let items = ChatScreenViewModel.project(messages: messages, toolCalls: toolCalls, checkpoint: nil)
        guard case .assistantText(_, _, _, _, let calls) = items[0] else {
            Issue.record("expected assistant row")
            return
        }
        #expect(calls[0].status == .running)
        #expect(calls[1].status == .failed)
    }
}
