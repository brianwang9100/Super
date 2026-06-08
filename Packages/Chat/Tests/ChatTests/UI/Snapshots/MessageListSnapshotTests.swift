#if canImport(UIKit)
import Core
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
    /// Register Core's bundled brand fonts before any render so this suite
    /// is order-independent in the shared test process (the xctest host never
    /// runs the app's font registration). See SnapshotFontRegistration.
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

    @Test("populated list in sepia theme")
    func populatedSepia() {
        verify(theme: .sepiaLight, name: "list_populated_sepia")
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

    // MARK: - Streaming markdown — partial-input variants
    //
    // These cover the in-flight rendering pipeline: `StreamingTail` runs
    // its text through `MarkdownText(treatAsPartial: true)`, which closes
    // dangling fences/links/emphasis via `MarkdownAutocloser` so the
    // overlay doesn't visually break while the closer is still in flight.
    // Each variant exercises one shape of partial markdown.

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

    @Test("streaming tail mid-fence in sepia theme")
    func streamingTailMidFenceSepia() {
        verifyStreamingMarkdown(
            text: """
            Here's the snippet:

            ```swift
            let total = items.reduce(0, +)
            print(total)
            """,
            theme: .sepiaLight,
            name: "list_streaming_midfence_sepia"
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

    @Test("streaming tail mid-bold in dark theme")
    func streamingTailMidBoldDark() {
        verifyStreamingMarkdown(
            text: "The key insight is that **partial markdown",
            theme: .vellumDark,
            name: "list_streaming_midbold_dark"
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

    @Test("streaming tail mid-list in dark theme")
    func streamingTailMidListDark() {
        verifyStreamingMarkdown(
            text: """
            Three things to remember:

            - first item complete
            - second item complete
            - third item
            """,
            theme: .vellumDark,
            name: "list_streaming_midlist_dark"
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

    @Test("streaming tail with inline code mid-formation in dark theme")
    func streamingTailMidInlineCodeDark() {
        verifyStreamingMarkdown(
            text: "Wrap the value in `Array(",
            theme: .vellumDark,
            name: "list_streaming_midcode_dark"
        )
    }

    /// Renders a streaming-overlay snapshot with `tail.text == text`,
    /// the same harness the four mid-* variants share. Frame matches the
    /// existing `streamingTail` baseline at 402×600.
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

    /// Banner with the optional action button — exercises the M11
    /// "Settings" deep-link variant that voice-input permission denial
    /// surfaces. Verifies the action label replaces the default Retry
    /// pill.
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

    @Test("compaction banner placement")
    func compactionBanner() {
        let function = #function
        let withBanner: [MessageList.Item] = [
            .userBubble(id: "u1", text: "older", references: []),
            .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: "earlier reply", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
            .compactionBanner(id: "b1", summary: "User said hello, assistant replied with the time."),
            .userBubble(id: "u2", text: "follow-up", references: []),
        ]
        let view = MessageList(items: withBanner, verbosity: .verbose)
            .superTheme(.make(.vellumLight))
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
                .userBubble(id: "u1", text: "Plan a long weekend in Lisbon", references: []),
                .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: markdown, toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
            ],
            verbosity: .verbose
        )
        .superTheme(.make(.vellumLight))
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
                .userBubble(id: "u1", text: "Show me a fetch helper", references: []),
                .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: markdown, toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
            ],
            verbosity: .verbose
        )
        .superTheme(.make(.vellumLight))
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
                .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: markdown, toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
            ],
            verbosity: .verbose
        )
        .superTheme(.make(.vellumLight))
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
            .userBubble(id: "u1", text: "older", references: []),
            .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: "earlier reply", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
            .compactionBanner(id: "b1", summary: summary),
            .userBubble(id: "u2", text: "follow-up", references: []),
        ], verbosity: .verbose)
        .superTheme(.make(.vellumLight))
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
            .userBubble(id: "u1", text: "Plan a long weekend in Lisbon", references: []),
            .assistantText(
                id: "a1",
                thinking: thinking,
                thinkingDurationMs: 4200,
                text: "Here's a starter itinerary.",
                toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil
            ),
        ], verbosity: .verbose)
        .superTheme(.make(.vellumLight))
        .frame(width: 402, height: 600)
        recordOrCompare(view: view, name: "list_thinking_markdown_light", function: function)
    }

    /// Appearance: minimum font scale (0.80×). Covers the lower-bound
    /// of the `ChatAppearance` knob — markdown body, user bubble text,
    /// paragraph line-spacing, and per-row vertical padding all
    /// interpolate to the compact anchor values, reading tighter than
    /// the default `list_populated_light` baseline.
    @Test("appearance: scale min")
    func appearanceScaleMin() {
        verifyAppearance(
            fontScale: 0.80,
            name: "list_scale_min_light"
        )
    }

    /// Appearance: maximum font scale (1.20×). Covers the upper-bound
    /// of the knob — markdown body and user bubble text scale up;
    /// paragraph line-spacing and per-row padding interpolate to the
    /// spacious anchor values.
    @Test("appearance: scale max")
    func appearanceScaleMax() {
        verifyAppearance(
            fontScale: 1.20,
            name: "list_scale_max_light"
        )
    }

    /// Dark-mode coverage at the upper-bound. Per AGENTS.md §Testing.2
    /// every new SwiftUI variant needs a light + dark pair. The
    /// light-theme matrix above already locks the rest of the
    /// font-scale knob range.
    @Test("appearance: scale max (dark)")
    func appearanceScaleMaxDark() {
        verifyAppearance(
            fontScale: 1.20,
            name: "list_scale_max_dark",
            theme: .vellumDark
        )
    }

    /// Sepia coverage at the upper-bound. The sepia palette uses a
    /// warmer background and ink than light/dark — confirms the
    /// appearance knob interacts correctly with that palette too (no
    /// hardcoded `.primary` foregrounds slipping through).
    @Test("appearance: scale max (sepia)")
    func appearanceScaleMaxSepia() {
        verifyAppearance(
            fontScale: 1.20,
            name: "list_scale_max_sepia",
            theme: .sepiaLight
        )
    }

    /// Combined Dynamic Type XXL + maxed appearance knob. Locks the
    /// "everything turned up" corner so a regression that compounds
    /// across `@ScaledMetric` + `fontScale` + spacious-anchor padding
    /// is caught in one baseline rather than three.
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

    /// Dynamic Type XXL coverage for the streaming overlay's partial
    /// markdown path. AGENTS.md §Testing.3 requires "at minimum one
    /// larger Dynamic Type size" for new SwiftUI views; the mid-list
    /// shape reflows non-trivially under accessibility-large type
    /// (per-row line wrapping, marker indentation) so it's the most
    /// likely surface to surface a regression.
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
    //
    // ``ThinkingBlock`` passes `treatAsPartial: true` to ``MarkdownText``
    // when its `durationSource` is `.live` (mid-stream). The variants
    // below exercise that path with a non-empty thinking buffer that
    // carries a dangling fence — the autocloser must close it so the
    // thinking body doesn't flip into a code block while the closer is
    // still in flight.

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

    /// Renders a streaming-overlay snapshot whose live thinking trace
    /// is non-empty (`thinkingStartedAt` set → ``ThinkingBlock`` flags
    /// the duration source as `.live` → ``MarkdownText`` enters the
    /// partial-input mode). `verbosity: .verbose` opens the trace so
    /// the body is visible to the snapshot.
    ///
    /// `thinkingStartedAt` is intentionally placed in the future so
    /// the `TimelineView`'s `max(0, elapsed)` clamps the displayed
    /// counter to "0s" across runs — otherwise the snapshot would
    /// drift with wall-clock time.
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

    // AGENTS.md §Testing.2 calls for a Reduce Motion snapshot on any view
    // with animation. SwiftUI's `\.accessibilityReduceMotion` env value
    // is read-only, so we can't flip it from a test wrapper. The
    // remaining animated surface in the streaming overlay is
    // `WaitingSpark` (which short-circuits its rotation when reduce
    // motion is on), but its steady-state first frame is identical
    // either way and the behavioral difference would only show after
    // the first tick. Snapshot parity therefore adds no signal; the
    // reduce-motion branch is verified by the conditional in source.
    // Tracked for revisit if a reliable env-injection seam appears in
    // a future SDK.

    /// Regression: a freshly-mounted `MessageList` with an overflowing
    /// transcript anchors at the latest message rather than the top.
    /// Thirty short bubbles overflow the 402×700 frame, so the
    /// top-vs-bottom diff is unambiguous. Cross-conversation reset
    /// (each chat re-anchors instead of inheriting a prior offset)
    /// depends on the host applying `.id(...)` to force a fresh view
    /// identity per chat — that path is covered by manual verification.
    @Test("freshly mounted long transcript anchors at bottom (light)")
    func freshlyMountedLongTranscriptLight() {
        verifyLongTranscript(theme: .vellumLight, name: "list_long_transcript_anchored_bottom")
    }

    @Test("freshly mounted long transcript anchors at bottom (dark)")
    func freshlyMountedLongTranscriptDark() {
        verifyLongTranscript(theme: .vellumDark, name: "list_long_transcript_anchored_bottom_dark")
    }

    @Test("freshly mounted long transcript anchors at bottom (sepia)")
    func freshlyMountedLongTranscriptSepia() {
        verifyLongTranscript(theme: .sepiaLight, name: "list_long_transcript_anchored_bottom_sepia")
    }

    // **No XXL variant for the anchor-at-bottom test.** At XXL Dynamic
    // Type the assistant row's SF Symbol message-action icons (copy,
    // regenerate) scale up, and their outer edges land on pixels that
    // flip from transparent background to fully-opaque ink — a per-pixel
    // LAB delta near ~50 % across machines, even though the visual
    // change is purely sub-pixel. Both the difference image and 5
    // consecutive CI runs on PR #30 confirmed only those icon edges
    // differ; bubble content, scroll position, and layout are pixel-
    // identical. The only tolerance combo that lets CI's measured floor
    // pass — `precision: 0.95, perceptualPrecision: 0.5` — is wider than
    // AGENTS.md §Testing.5 allows ("a real regression would still
    // register at the chosen tolerance"). Per that same rule's escape
    // hatch we drop the XXL variant rather than loosen the tolerance:
    // the three theme variants above still exercise the freshly-mounted-
    // anchor logic at exact-pixel precision; the only thing lost is
    // catching an XXL-specific layout regression on the long transcript,
    // which the matrix's other `dynamicTypeXXL` baselines cover with
    // shorter content.

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

    /// 30 user/assistant pairs — enough rows to overflow the 402×700
    /// snapshot frame so the initial-bottom-anchor latch can be observed.
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

    /// Renders the populated `items` fixture under a non-default
    /// `ChatAppearance` and snapshots in the given theme. Used to lock
    /// in the endpoints of the font-scale knob.
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
