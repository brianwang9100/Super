#if canImport(UIKit)
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Coverage on `MessageList`: a representative populated transcript
/// (user bubble, assistant text, tool call, banner) per theme. The view
/// is fed pre-baked items so the test stays free of GRDB and doesn't
/// depend on a reactive query.
@Suite("MessageList snapshots", .serialized)
@MainActor
struct MessageListSnapshotTests {
    private let items: [MessageList.Item] = [
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
        let tail = MessageList.StreamingState(
            thinking: "",
            text: "Working on it",
            isCompacting: false
        )
        let view = MessageList(
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
        let view = MessageList(
            items: [.userBubble(id: "u1", text: "What now?")],
            error: .init(message: "Authentication failed. Check the API key in Settings.")
        )
        .superTheme(.make(.light))
        .frame(width: 402, height: 400)
        recordOrCompare(view: view, name: "list_error_light", function: function)
    }

    /// Banner with the optional action button — exercises the M11
    /// "Settings" deep-link variant that voice-input permission denial
    /// surfaces. Verifies the action label replaces the default Retry
    /// pill.
    @Test("error banner with action button (Settings variant)")
    func errorBannerWithAction() {
        let function = #function
        let view = MessageList(
            items: [.userBubble(id: "u1", text: "Try voice")],
            error: .init(
                message: "Voice input needs Speech Recognition and Microphone permissions. Open Settings to enable them.",
                actionLabel: "Settings",
                action: {}
            )
        )
        .superTheme(.make(.light))
        .frame(width: 402, height: 400)
        recordOrCompare(view: view, name: "list_error_banner_with_action_light", function: function)
    }

    @Test("compaction banner placement")
    func compactionBanner() {
        let function = #function
        let withBanner: [MessageList.Item] = [
            .userBubble(id: "u1", text: "older"),
            .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: "earlier reply", toolCalls: []),
            .compactionBanner(id: "b1", summary: "User said hello, assistant replied with the time."),
            .userBubble(id: "u2", text: "follow-up"),
        ]
        let view = MessageList(items: withBanner, verbosity: .verbose)
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
        let view = MessageList(
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

    /// Fenced ```swift code block rendered through ``CodeBlock`` —
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
        let view = MessageList(
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
        let view = MessageList(
            items: [
                .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: markdown, toolCalls: []),
            ],
            verbosity: .verbose
        )
        .superTheme(.make(.light))
        .frame(width: 402, height: 500)
        recordOrCompare(view: view, name: "list_table_light", function: function)
    }

    /// Compaction banner whose summary contains markdown (`**bold**` and
    /// inline `code`). Exercises `MarkdownText.BodyStyle.banner` so a
    /// future tweak to the banner's foreground/font/italic story is
    /// caught visually rather than only by the unit-level pin.
    @Test("compaction banner renders markdown in summary text")
    func compactionBannerWithMarkdown() {
        let function = #function
        let summary = "User asked about **Lisbon** itinerary; assistant replied with `tram 28` and pastry-shop tips."
        let view = MessageList(items: [
            .userBubble(id: "u1", text: "older"),
            .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: "earlier reply", toolCalls: []),
            .compactionBanner(id: "b1", summary: summary),
            .userBubble(id: "u2", text: "follow-up"),
        ], verbosity: .verbose)
        .superTheme(.make(.light))
        .frame(width: 402, height: 600)
        recordOrCompare(view: view, name: "list_compaction_markdown_light", function: function)
    }

    /// Thinking trace expanded under verbose verbosity, containing
    /// markdown (a bulleted list + **bold**). Exercises
    /// `MarkdownText.BodyStyle.thinking` so the italic + softer-ink
    /// styling stays coherent with markdown structure inside the trace.
    @Test("thinking trace renders markdown when expanded")
    func thinkingBlockWithMarkdown() {
        let function = #function
        let thinking = """
        Thinking through the trip:

        - **Three days** is enough to see the historic center
        - Belém needs its own half-day
        - Save Sintra for a day trip
        """
        let view = MessageList(items: [
            .userBubble(id: "u1", text: "Plan a long weekend in Lisbon"),
            .assistantText(
                id: "a1",
                thinking: thinking,
                thinkingDurationMs: 4200,
                text: "Here's a starter itinerary.",
                toolCalls: []
            ),
        ], verbosity: .verbose)
        .superTheme(.make(.light))
        .frame(width: 402, height: 600)
        recordOrCompare(view: view, name: "list_thinking_markdown_light", function: function)
    }

    @Test("dynamic type XXL light")
    func dynamicTypeXXL() {
        let function = #function
        let view = MessageList(items: items, verbosity: .verbose)
            .superTheme(.make(.light))
            .dynamicTypeSize(.xxLarge)
            .frame(width: 402, height: 700)
        recordOrCompare(view: view, name: "list_populated_light_xxl", function: function)
    }

    /// Dynamic Type XXL coverage for the M10 markdown surfaces — body
    /// prose, fenced code, and a table all under accessibility-large
    /// type. Per AGENTS.md §Testing.2 every view needs a larger Dynamic
    /// Type snapshot; the base `dynamicTypeXXL` fixture has no markdown
    /// content so it doesn't exercise these paths.
    @Test("dynamic type XXL markdown + code block + table")
    func dynamicTypeXXLMarkdown() {
        let function = #function
        let markdown = """
        ### Lisbon trip checklist

        Three days in Lisbon mixes **steep hills** with `tram 28` rides.

        ```swift
        func plan(days: Int) -> String { "\\(days)d" }
        ```

        | Day | Focus |
        | --- | --- |
        | 1 | Alfama |
        | 2 | Belém |
        """
        let view = MessageList(
            items: [
                .userBubble(id: "u1", text: "Plan a long weekend in Lisbon"),
                .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: markdown, toolCalls: []),
            ],
            verbosity: .verbose
        )
        .superTheme(.make(.light))
        .dynamicTypeSize(.xxLarge)
        .frame(width: 402, height: 900)
        recordOrCompare(view: view, name: "list_markdown_light_xxl", function: function)
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
        let view = MessageList(items: items, verbosity: .verbose)
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
