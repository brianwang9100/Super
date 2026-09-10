#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Chat

@Suite("MessageList snapshots", .serialized)
@MainActor
struct MessageListSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }
    private let items: [MessageList.Item] = [
        .userBubble(id: "u1", text: "What's the time in Tokyo?", references: []),
        .assistantText(
            id: "a1",
            thinking: nil,
            thinkingDurationMs: nil,
            text: "Right now in Tokyo it's 9:47 AM JST.",
            toolCalls: [
                .init(
                    id: "t1",
                    toolName: "time.now",
                    toolDisplayName: "Current time",
                    parametersJSON: "{\"timezone\":\"Asia/Tokyo\"}",
                    resultText: "Current time: Saturday, April 25, 2026 at 9:47:00 AM JST",
                    status: .success
                )
            ],
            sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil
        ),
        .userBubble(id: "u2", text: "Thanks!", references: []),
    ]

    @Test("populated list in light theme")
    func populatedLight() {
        verify(theme: .vellumLight, name: "list_populated_light")
    }

    @Test("populated list in dark theme")
    func populatedDark() {
        verify(theme: .vellumDark, name: "list_populated_dark")
    }

    @Test("streaming tail with plain prose")
    func streamingTail() {
        let function = #function
        let tail = MessageList.StreamingState(
            thinking: "",
            text: "Working on it",
            isCompacting: false
        )
        let view = MessageList(
            items: [.userBubble(id: "u1", text: "Hi there", references: [])],
            streamingTail: tail,
            verbosity: .verbose
        )
        .superTheme(.make(.vellumLight))
        .frame(width: 402, height: 600)
        recordOrCompare(view: view, name: "list_streaming_light", function: function)
    }

    // MARK: - Streaming partial markdown

    @Test("streaming tail mid-fence (unclosed code block)")
    func streamingTailMidFence() {
        verifyStreamingMarkdown(
            text: """
            Here's the snippet:

            ```swift
            let total = items.reduce(0, +)
            print(total)
            """,
            theme: .vellumLight,
            name: "list_streaming_midfence_light"
        )
    }

    @Test("streaming tail mid-fence in dark theme")
    func streamingTailMidFenceDark() {
        verifyStreamingMarkdown(
            text: """
            Here's the snippet:

            ```swift
            let total = items.reduce(0, +)
            print(total)
            """,
            theme: .vellumDark,
            name: "list_streaming_midfence_dark"
        )
    }

    @Test("streaming tail mid-bold (unclosed emphasis)")
    func streamingTailMidBold() {
        verifyStreamingMarkdown(
            text: "The key insight is that **partial markdown",
            theme: .vellumLight,
            name: "list_streaming_midbold_light"
        )
    }

    @Test("streaming tail mid-list (third item just opened)")
    func streamingTailMidList() {
        verifyStreamingMarkdown(
            text: """
            Three things to remember:

            - first item complete
            - second item complete
            - third item
            """,
            theme: .vellumLight,
            name: "list_streaming_midlist_light"
        )
    }

    @Test("streaming tail with inline code mid-formation")
    func streamingTailMidInlineCode() {
        verifyStreamingMarkdown(
            text: "Wrap the value in `Array(",
            theme: .vellumLight,
            name: "list_streaming_midcode_light"
        )
    }

    private func verifyStreamingMarkdown(
        text: String,
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let tail = MessageList.StreamingState(
            thinking: "",
            text: text,
            isCompacting: false
        )
        let view = MessageList(
            items: [.userBubble(id: "u1", text: "Show me", references: [])],
            streamingTail: tail,
            verbosity: .verbose
        )
        .superTheme(.make(theme))
        .frame(width: 402, height: 600)
        recordOrCompare(view: view, name: name, function: function)
    }

    @Test("error banner above composer")
    func errorBanner() {
        let function = #function
        let view = MessageList(
            items: [.userBubble(id: "u1", text: "What now?", references: [])],
            error: .init(message: "Authentication failed. Check the API key in Settings.")
        )
        .superTheme(.make(.vellumLight))
        .frame(width: 402, height: 400)
        recordOrCompare(view: view, name: "list_error_light", function: function)
    }

    @Test("error banner with action button (Settings variant)")
    func errorBannerWithAction() {
        let function = #function
        let view = MessageList(
            items: [.userBubble(id: "u1", text: "Try voice", references: [])],
            error: .init(
                message: "Voice input needs Speech Recognition and Microphone permissions. Open Settings to enable them.",
                actionLabel: "Settings",
                action: {}
            )
        )
        .superTheme(.make(.vellumLight))
        .frame(width: 402, height: 400)
        recordOrCompare(view: view, name: "list_error_banner_with_action_light", function: function)
    }

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
                .userBubble(id: "u1", text: "Plan a long weekend in Lisbon", references: []),
                .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: markdown, toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
            ],
            verbosity: .verbose
        )
        .superTheme(.make(.vellumLight))
        .frame(width: 402, height: 700)
        recordOrCompare(view: view, name: "list_markdown_light", function: function)
    }

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
                .userBubble(id: "u1", text: "Show me a fetch helper", references: []),
                .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: markdown, toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
            ],
            verbosity: .verbose
        )
        .superTheme(.make(.vellumLight))
        .frame(width: 402, height: 700)
        recordOrCompare(view: view, name: "list_codeblock_light", function: function)
    }

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
                .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: markdown, toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
            ],
            verbosity: .verbose
        )
        .superTheme(.make(.vellumLight))
        .frame(width: 402, height: 500)
        recordOrCompare(view: view, name: "list_table_light", function: function)
    }

    @Test("compaction banner renders markdown in summary text")
    func compactionBannerWithMarkdown() {
        let function = #function
        let summary = "User asked about **Lisbon** itinerary; assistant replied with `tram 28` and pastry-shop tips."
        let view = MessageList(items: [
            .userBubble(id: "u1", text: "older", references: []),
            .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: "earlier reply", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
            .compactionBanner(id: "b1", summary: summary),
            .userBubble(id: "u2", text: "follow-up", references: []),
        ], verbosity: .verbose)
        .superTheme(.make(.vellumLight))
        .frame(width: 402, height: 600)
        recordOrCompare(view: view, name: "list_compaction_markdown_light", function: function)
    }

    @Test("thinking trace renders markdown when expanded")
    func thinkingBlockWithMarkdown() {
        let function = #function
        recordOrCompare(
            view: thinkingMarkdownList(theme: .vellumLight),
            name: "list_thinking_markdown_light",
            function: function
        )
    }

    @Test("thinking trace renders markdown when expanded (dark)")
    func thinkingBlockWithMarkdownDark() {
        let function = #function
        recordOrCompare(
            view: thinkingMarkdownList(theme: .vellumDark),
            name: "list_thinking_markdown_dark",
            function: function
        )
    }

    private func thinkingMarkdownList(theme: SuperTheme.Identifier) -> some View {
        let thinking = """
        Thinking through the trip:

        - **Three days** is enough to see the historic center
        - Belém needs its own half-day
        - Save Sintra for a day trip
        """
        return MessageList(items: [
            .userBubble(id: "u1", text: "Plan a long weekend in Lisbon", references: []),
            .assistantText(
                id: "a1",
                thinking: thinking,
                thinkingDurationMs: 4200,
                text: "Here's a starter itinerary.",
                toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil
            ),
        ], verbosity: .verbose)
        .superTheme(.make(theme))
        .frame(width: 402, height: 600)
    }

    @Test("appearance: scale min")
    func appearanceScaleMin() {
        verifyAppearance(
            fontScale: 0.80,
            name: "list_scale_min_light"
        )
    }

    @Test("appearance: scale max")
    func appearanceScaleMax() {
        verifyAppearance(
            fontScale: 1.20,
            name: "list_scale_max_light"
        )
    }

    /// Combines Dynamic Type, app font scale, and spacious padding to catch compounded scaling.
    @Test("appearance: scale max at dynamic type XXL")
    func appearanceScaleMaxXXL() {
        let function = #function
        let view = MessageList(items: items, verbosity: .verbose)
            .superTheme(.make(.vellumLight))
            .chatAppearance(ChatAppearance(fontScale: 1.20))
            .superTypography(.make(.serif, fontScale: 1.20))
            .dynamicTypeSize(.xxLarge)
            .frame(width: 402, height: 700)
        recordOrCompare(view: view, name: "list_scale_max_light_xxl", function: function)
    }

    @Test("dynamic type XXL light")
    func dynamicTypeXXL() {
        let function = #function
        let view = MessageList(items: items, verbosity: .verbose)
            .superTheme(.make(.vellumLight))
            .dynamicTypeSize(.xxLarge)
            .frame(width: 402, height: 700)
        recordOrCompare(view: view, name: "list_populated_light_xxl", function: function)
    }

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
                .userBubble(id: "u1", text: "Plan a long weekend in Lisbon", references: []),
                .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: markdown, toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
            ],
            verbosity: .verbose
        )
        .superTheme(.make(.vellumLight))
        .dynamicTypeSize(.xxLarge)
        .frame(width: 402, height: 900)
        recordOrCompare(view: view, name: "list_markdown_light_xxl", function: function)
    }

    @Test("dynamic type XXL streaming tail mid-list (light)")
    func streamingTailMidListLightXXL() {
        let function = #function
        let tail = MessageList.StreamingState(
            thinking: "",
            text: """
            Three things to remember:

            - first item complete
            - second item complete
            - third item
            """,
            isCompacting: false
        )
        let view = MessageList(
            items: [.userBubble(id: "u1", text: "Show me", references: [])],
            streamingTail: tail,
            verbosity: .verbose
        )
        .superTheme(.make(.vellumLight))
        .dynamicTypeSize(.xxLarge)
        .frame(width: 402, height: 900)
        recordOrCompare(view: view, name: "list_streaming_midlist_light_xxl", function: function)
    }

    // MARK: - Live-thinking partial markdown

    @Test("streaming tail with mid-fence thinking trace (light)")
    func streamingTailThinkingMidFenceLight() {
        verifyStreamingThinking(
            thinking: """
            Considering the snippet:

            ```swift
            let total = items.reduce(
            """,
            theme: .vellumLight,
            name: "list_streaming_thinking_midfence_light"
        )
    }

    @Test("streaming tail with mid-fence thinking trace (dark)")
    func streamingTailThinkingMidFenceDark() {
        verifyStreamingThinking(
            thinking: """
            Considering the snippet:

            ```swift
            let total = items.reduce(
            """,
            theme: .vellumDark,
            name: "list_streaming_thinking_midfence_dark"
        )
    }

    /// A future thinking start clamps elapsed time to zero for stable TimelineView output.
    private func verifyStreamingThinking(
        thinking: String,
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let tail = MessageList.StreamingState(
            thinking: thinking,
            thinkingStartedAt: Date().addingTimeInterval(86400),
            text: "",
            isCompacting: false
        )
        let view = MessageList(
            items: [.userBubble(id: "u1", text: "Walk me through it", references: [])],
            streamingTail: tail,
            verbosity: .verbose
        )
        .superTheme(.make(theme))
        .frame(width: 402, height: 700)
        recordOrCompare(view: view, name: name, function: function)
    }

    @Test("freshly mounted long transcript anchors at bottom (light)")
    func freshlyMountedLongTranscriptLight() {
        verifyLongTranscript(theme: .vellumLight, name: "list_long_transcript_anchored_bottom")
    }

    @Test("focused turn keeps its question at the top after a short answer")
    func focusedTurn() {
        let transcript = Self.longTranscriptItems + [
            .userBubble(id: "focused-question", text: "What does it mean to love your neighbor?", references: []),
            .assistantText(
                id: "focused-answer", thinking: nil, thinkingDurationMs: nil,
                text: "It means treating another person's good as something worth your care.",
                toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil
            )
        ]
        let view = MessageList(
            items: transcript,
            scrollRequest: .init(messageID: "focused-question", sequence: 1)
        )
        .superTheme(.make(.vellumLight))
        .frame(width: 402, height: 700)
        recordOrCompare(view: view, name: "focused_turn_short_answer")
    }

    @Test("freshly mounted long transcript anchors at bottom (dark)")
    func freshlyMountedLongTranscriptDark() {
        verifyLongTranscript(theme: .vellumDark, name: "list_long_transcript_anchored_bottom_dark")
    }

    // The long-transcript XXL fixture exceeded tolerance on cross-runner icon edges
    // in PR #30. Keep exact comparison here; shorter XXL fixtures cover text reflow.

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

    private static let longTranscriptItems: [MessageList.Item] = (1...30).flatMap { i in
        [
            MessageList.Item.userBubble(id: "u\(i)", text: "User question \(i)", references: []),
            MessageList.Item.assistantText(
                id: "a\(i)",
                thinking: nil,
                thinkingDurationMs: nil,
                text: "Assistant reply \(i).",
                toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil
            ),
        ]
    }

    private func verifyLongTranscript(
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let view = MessageList(items: Self.longTranscriptItems, verbosity: .verbose)
            .superTheme(.make(theme))
            .frame(width: 402, height: 700)
        recordOrCompare(view: view, name: name, function: function)
    }

    private func verifyAppearance(
        fontScale: Double,
        name: String,
        theme: SuperTheme.Identifier = .vellumLight,
        function: String = #function
    ) {
        let view = MessageList(items: items, verbosity: .verbose)
            .superTheme(.make(theme))
            .chatAppearance(ChatAppearance(fontScale: fontScale))
            .superTypography(.make(.serif, fontScale: fontScale))
            .frame(width: 402, height: 700)
        recordOrCompare(view: view, name: name, function: function)
    }

    private func recordOrCompare<V: View>(
        view: V,
        name: String,
        function: String = #function
    ) {
        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 700)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
