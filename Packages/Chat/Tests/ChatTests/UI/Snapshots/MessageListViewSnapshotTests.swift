#if canImport(UIKit)
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Coverage on `MessageListView`: a representative populated transcript
/// (user bubble, assistant text, tool call, banner) per theme. The view
/// is fed pre-baked items so the test stays free of GRDB and doesn't
/// depend on a reactive query.
@Suite("MessageListView snapshots", .serialized)
@MainActor
struct MessageListViewSnapshotTests {
    private let items: [MessageListView.Item] = [
        .userBubble(id: "u1", text: "What's the time in Tokyo?"),
        .assistantText(
            id: "a1",
            thinking: nil,
            thinkingDurationMs: nil,
            text: "Right now in Tokyo it's 9:47 AM JST.",
            toolCalls: [
                .init(
                    id: "t1",
                    toolName: "time.now",
                    parametersJSON: "{\"timezone\":\"Asia/Tokyo\"}",
                    resultText: "Current time: Saturday, April 25, 2026 at 9:47:00 AM JST",
                    status: .success
                )
            ]
        ),
        .userBubble(id: "u2", text: "Thanks!"),
    ]

    @Test("populated list in light theme")
    func populatedLight() {
        verify(theme: .light, name: "list_populated_light")
    }

    @Test("populated list in dark theme")
    func populatedDark() {
        verify(theme: .dark, name: "list_populated_dark")
    }

    @Test("populated list in sepia theme")
    func populatedSepia() {
        verify(theme: .sepia, name: "list_populated_sepia")
    }

    @Test("streaming tail with typing caret")
    func streamingTail() {
        let function = #function
        let tail = MessageListView.StreamingTail(
            thinking: "",
            text: "Working on it",
            isCompacting: false
        )
        let view = MessageListView(
            items: [.userBubble(id: "u1", text: "Hi there")],
            streamingTail: tail,
            verbosity: .verbose
        )
        .superTheme(.make(.light))
        .frame(width: 402, height: 600)
        recordOrCompare(view: view, name: "list_streaming_light", function: function)
    }

    @Test("error banner above composer")
    func errorBanner() {
        let function = #function
        let view = MessageListView(
            items: [.userBubble(id: "u1", text: "What now?")],
            error: .init(message: "Authentication failed. Check the API key in Settings.")
        )
        .superTheme(.make(.light))
        .frame(width: 402, height: 400)
        recordOrCompare(view: view, name: "list_error_light", function: function)
    }

    @Test("compaction banner placement")
    func compactionBanner() {
        let function = #function
        let withBanner: [MessageListView.Item] = [
            .userBubble(id: "u1", text: "older"),
            .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: "earlier reply", toolCalls: []),
            .compactionBanner(id: "b1", summary: "User said hello, assistant replied with the time."),
            .userBubble(id: "u2", text: "follow-up"),
        ]
        let view = MessageListView(items: withBanner, verbosity: .verbose)
            .superTheme(.make(.light))
            .frame(width: 402, height: 600)
        recordOrCompare(view: view, name: "list_compaction_light", function: function)
    }

    /// Markdown coverage: paragraphs, **bold**, `inline code`, a bulleted
    /// list, and an h3 heading. Stresses the M10 `markdownTheme()` text
    /// styles + paragraph spacing.
    @Test("markdown content (paragraphs, lists, headings, inline code)")
    func markdownContent() {
        let function = #function
        let markdown = """
        ### Lisbon trip checklist

        Lisbon mixes **steep hills** with `tram 28` rides and pastel-de-nata stops. A few essentials:

        - Book the Belém pastry shop slot in advance
        - Carry a transit card for the trams
        - Pack layers — mornings are cool

        Wrap up with a sunset at *Miradouro da Senhora do Monte*.
        """
        let view = MessageListView(
            items: [
                .userBubble(id: "u1", text: "Plan a long weekend in Lisbon"),
                .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: markdown, toolCalls: []),
            ],
            verbosity: .verbose
        )
        .superTheme(.make(.light))
        .frame(width: 402, height: 700)
        recordOrCompare(view: view, name: "list_markdown_light", function: function)
    }

    /// Fenced ```swift code block rendered through ``CodeBlockView`` —
    /// covers the dark surface, lang label, copy pill, and Splash-driven
    /// keyword/string/comment coloring.
    @Test("fenced code block with Splash highlighting")
    func codeBlock() {
        let function = #function
        let markdown = """
        Here's a tiny Swift snippet that loads a row by id:

        ```swift
        // Fetch a single conversation by id.
        func conversation(id: String) async throws -> ConversationRecord? {
            try await db.read { db in
                try ConversationRecord
                    .filter(Column("id") == id)
                    .fetchOne(db)
            }
        }
        ```

        Call it from the view model on a `.task` modifier.
        """
        let view = MessageListView(
            items: [
                .userBubble(id: "u1", text: "Show me a fetch helper"),
                .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: markdown, toolCalls: []),
            ],
            verbosity: .verbose
        )
        .superTheme(.make(.light))
        .frame(width: 402, height: 700)
        recordOrCompare(view: view, name: "list_codeblock_light", function: function)
    }

    /// GFM table coverage. Tests the `Theme.table` chrome (rounded border,
    /// horizontal scroll wrapper) and the cell styling.
    @Test("GFM table renders with chrome")
    func table() {
        let function = #function
        let markdown = """
        Here are the runtime knobs:

        | Setting | Default | Notes |
        | --- | --- | --- |
        | `temperature` | 0.7 | Per-call override |
        | `top_p` | 1.0 | Nucleus sampling |
        | `max_tokens` | 2048 | Hard cap |
        """
        let view = MessageListView(
            items: [
                .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: markdown, toolCalls: []),
            ],
            verbosity: .verbose
        )
        .superTheme(.make(.light))
        .frame(width: 402, height: 500)
        recordOrCompare(view: view, name: "list_table_light", function: function)
    }

    @Test("dynamic type XXL light")
    func dynamicTypeXXL() {
        let function = #function
        let view = MessageListView(items: items, verbosity: .verbose)
            .superTheme(.make(.light))
            .dynamicTypeSize(.xxLarge)
            .frame(width: 402, height: 700)
        recordOrCompare(view: view, name: "list_populated_light_xxl", function: function)
    }

    // AGENTS.md §Testing.2 calls for a Reduce Motion snapshot on any view
    // with animation. SwiftUI's `\.accessibilityReduceMotion` env value
    // is read-only, so we can't flip it from a test wrapper. The
    // `TypingCaret.body` does branch on it (`onAppear` early-returns when
    // the env reads true) but the steady-state first frame is identical
    // either way — visible: true. The behavioral difference would only
    // show after the first animation tick. Snapshot parity therefore
    // adds no signal here; the reduce-motion branch in TypingCaret is
    // verified by the conditional in source. Tracked for revisit if a
    // reliable env-injection seam appears in a future SDK.

    private func verify(
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let view = MessageListView(items: items, verbosity: .verbose)
            .superTheme(.make(theme))
            .frame(width: 402, height: 700)
        recordOrCompare(view: view, name: name, function: function)
    }

    private func recordOrCompare<V: View>(
        view: V,
        name: String,
        function: String = #function
    ) {
        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 700)),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
