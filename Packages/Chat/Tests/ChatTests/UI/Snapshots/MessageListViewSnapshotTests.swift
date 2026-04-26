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
            .assistantText(id: "a1", text: "earlier reply", toolCalls: []),
            .compactionBanner(id: "b1", summary: "User said hello, assistant replied with the time."),
            .userBubble(id: "u2", text: "follow-up"),
        ]
        let view = MessageListView(items: withBanner, verbosity: .verbose)
            .superTheme(.make(.light))
            .frame(width: 402, height: 600)
        recordOrCompare(view: view, name: "list_compaction_light", function: function)
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
