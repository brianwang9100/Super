import Core
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
        if case .userBubble(let id, let text, _) = items[0] {
            #expect(id == "u1")
            #expect(text == "hello")
        } else {
            Issue.record("expected user bubble")
        }
        if case .assistantText(let id, let thinking, let durationMs, let text, let calls, _, _, _, _) = items[1] {
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
        guard case .assistantText(_, let thinking, let durationMs, let text, _, _, _, _, _) = items[0] else {
            Issue.record("expected assistant row")
            return
        }
        #expect(thinking == "let me think... it must be 42")
        #expect(durationMs == 4_200)
        #expect(text == "the answer is 42")
    }

    @Test("duplicate toolCallId across tool messages does not trap")
    func duplicateToolCallIdDoesNotTrap() {
        // Regression: Gemini parallel calls to the SAME tool persisted two
        // tool-result messages sharing one toolCallId. project()'s
        // Dictionary(uniqueKeysWithValues:) trapped on the duplicate key,
        // crashing the app on every refresh and on chat reopen (the
        // bible-"wrath" crash). Projection of stored data must never trap.
        let messages: [MessageRecord] = [
            MessageRecord(id: "a1", conversationId: "c", role: .assistant, content: "", createdAt: now),
            MessageRecord(id: "t1", conversationId: "c", role: .tool, content: "James 1", toolCallId: "bible.lookup", createdAt: now.addingTimeInterval(1)),
            MessageRecord(id: "t2", conversationId: "c", role: .tool, content: "Romans 2", toolCallId: "bible.lookup", createdAt: now.addingTimeInterval(2)),
        ]
        let items = ChatScreenViewModel.project(messages: messages, toolCalls: [], checkpoint: nil)
        // Returns without trapping; the assistant row projects (tool rows fold).
        #expect(items.count == 1)
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
        guard case .assistantText(_, _, _, _, let calls, _, _, _, _) = items[1] else {
            Issue.record("expected assistant row at index 1")
            return
        }
        #expect(calls.count == 1)
        #expect(calls[0].toolName == "time.now")
        #expect(calls[0].status == .success)
        #expect(calls[0].resultText == "It is 3pm.")
    }

    @Test("toolDisplayNames maps the technical name to a friendly label; unmapped falls back")
    func toolDisplayNameResolves() {
        let messages: [MessageRecord] = [
            MessageRecord(id: "a1", conversationId: "c", role: .assistant, content: "", createdAt: now),
        ]
        let toolCalls: [ToolCallRecord] = [
            ToolCallRecord(id: "tc1", messageId: "a1", conversationId: "c", toolName: "time.now", parameters: "{}", result: nil, status: .executing, createdAt: now, completedAt: nil),
            ToolCallRecord(id: "tc2", messageId: "a1", conversationId: "c", toolName: "mystery.tool", parameters: "{}", result: nil, status: .executing, createdAt: now, completedAt: nil),
        ]

        let items = ChatScreenViewModel.project(
            messages: messages,
            toolCalls: toolCalls,
            checkpoint: nil,
            toolDisplayNames: ["time.now": "Current time"]
        )
        guard case .assistantText(_, _, _, _, let calls, _, _, _, _) = items[0] else {
            Issue.record("expected assistant row")
            return
        }
        #expect(calls.count == 2)
        // Mapped: technical `toolName` resolves to the friendly display name…
        #expect(calls[0].toolName == "time.now")
        #expect(calls[0].toolDisplayName == "Current time")
        // …and an unmapped tool falls back to its technical name.
        #expect(calls[1].toolDisplayName == "mystery.tool")
    }

    @Test("assistant web-search citations project onto the row as source pills")
    func sourceCitationsProject() {
        let attachments = MessageAttachments(sources: [
            SourceCitation(
                id: "https://www.nasa.gov/mars#0",
                title: "NASA: Mars Rover",
                url: URL(string: "https://www.nasa.gov/mars")!
            ),
            // No title → pill falls back to the host; leading www. stripped.
            SourceCitation(
                id: "https://space.com/rover#1",
                title: "",
                url: URL(string: "https://space.com/rover")!
            ),
        ])
        let items = ChatScreenViewModel.project(
            messages: [
                MessageRecord(
                    id: "a1", conversationId: "c", role: .assistant,
                    content: "The rover found water ice.", createdAt: now,
                    attachmentsJSON: MessageRecord.encode(attachments)
                ),
            ],
            toolCalls: [],
            checkpoint: nil
        )
        guard case .assistantText(_, _, _, _, _, let sources, _, _, _) = items[0] else {
            Issue.record("expected assistant row")
            return
        }
        #expect(sources.count == 2)
        #expect(sources[0].id == "https://www.nasa.gov/mars#0")
        #expect(sources[0].host == "nasa.gov")           // leading www. stripped
        #expect(sources[0].title == "NASA: Mars Rover")
        #expect(sources[1].host == "space.com")
        // A titleless source collapses to "" so the pill renders host-only,
        // rather than a redundant host + "space.com" title pair.
        #expect(sources[1].title == "")
        #expect(sources[1].url == URL(string: "https://space.com/rover")!)
    }

    @Test("a citation whose title merely repeats its host collapses to a host-only pill")
    func titleEqualToHostCollapses() {
        let attachments = MessageAttachments(sources: [
            // Title equals the www-prefixed host — redundant, should collapse.
            SourceCitation(id: "1", title: "www.example.com", url: URL(string: "https://www.example.com/page")!),
            // Title differs only in case from the host — must still collapse.
            SourceCitation(id: "2", title: "Space.com", url: URL(string: "https://space.com/x")!),
        ])
        let items = ChatScreenViewModel.project(
            messages: [
                MessageRecord(
                    id: "a1", conversationId: "c", role: .assistant, content: "ans",
                    createdAt: now, attachmentsJSON: MessageRecord.encode(attachments)
                ),
            ],
            toolCalls: [], checkpoint: nil
        )
        guard case .assistantText(_, _, _, _, _, let sources, _, _, _) = items[0] else {
            Issue.record("expected assistant row"); return
        }
        #expect(sources[0].host == "example.com")
        #expect(sources[0].title == "")
        #expect(sources[1].host == "space.com")
        #expect(sources[1].title == "")          // case-insensitive collapse
    }

    @Test("assistant row with no attachments projects no source pills")
    func noAttachmentsProjectsNoSources() {
        let items = ChatScreenViewModel.project(
            messages: [
                MessageRecord(id: "a1", conversationId: "c", role: .assistant, content: "hi", createdAt: now),
            ],
            toolCalls: [],
            checkpoint: nil
        )
        guard case .assistantText(_, _, _, _, _, let sources, let html, _, _) = items[0] else {
            Issue.record("expected assistant row")
            return
        }
        #expect(sources.isEmpty)
        #expect(html == nil)
    }

    @Test("Gemini search-suggestions HTML projects onto the assistant row")
    func searchSuggestionsHTMLProjects() {
        let attachments = MessageAttachments(
            searchSuggestionsHTML: "<div class=\"gsc\">chips</div>"
        )
        let items = ChatScreenViewModel.project(
            messages: [
                MessageRecord(
                    id: "a1", conversationId: "c", role: .assistant,
                    content: "The rover found water ice.", createdAt: now,
                    attachmentsJSON: MessageRecord.encode(attachments)
                ),
            ],
            toolCalls: [],
            checkpoint: nil
        )
        guard case .assistantText(_, _, _, _, _, _, let html, _, _) = items[0] else {
            Issue.record("expected assistant row")
            return
        }
        // Rendered unmodified by the always-visible suggestions strip.
        #expect(html == "<div class=\"gsc\">chips</div>")
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
        if case .userBubble(let id, _, _) = items[3] {
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
        guard case .assistantText(_, _, _, _, let calls, _, _, _, _) = items[0] else {
            Issue.record("expected assistant row")
            return
        }
        #expect(calls[0].status == .running)
        #expect(calls[1].status == .failed)
    }

    @Test("an awaiting-confirmation proposal projects with the awaitingConfirmation status")
    func awaitingConfirmationStatusSurfaces() {
        // The native web-search proposal parks at `.awaitingConfirmation`;
        // the projection must preserve that (not collapse it to running) so
        // the inline confirm row renders its approve/skip prompt.
        let messages: [MessageRecord] = [
            MessageRecord(id: "a1", conversationId: "c", role: .assistant, content: "", createdAt: now),
        ]
        let toolCalls: [ToolCallRecord] = [
            ToolCallRecord(
                id: "t1", messageId: "a1", conversationId: "c",
                toolName: NativeWebSearch.proposalToolName,
                parameters: #"{"query":"mars news","reason":"current events"}"#,
                status: .awaitingConfirmation, createdAt: now
            ),
        ]
        let items = ChatScreenViewModel.project(messages: messages, toolCalls: toolCalls, checkpoint: nil)
        guard case .assistantText(_, _, _, _, let calls, _, _, _, _) = items[0] else {
            Issue.record("expected assistant row")
            return
        }
        #expect(calls[0].status == .awaitingConfirmation)
        #expect(calls[0].toolName == NativeWebSearch.proposalToolName)
    }
}
