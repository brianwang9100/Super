#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Snapshots for the Copy + Regenerate action row beneath
/// ``AssistantMessage``. The interesting visual state added by this PR is
/// the `isStreaming: true` form where Regenerate dims to 40% opacity
/// while Copy stays at full opacity. Pins both states so a future tweak
/// to the disabled appearance can't drift silently.
///
/// Wider `MessageList` baselines already cover thinking / tool-call /
/// markdown surfaces, so this suite focuses narrowly on the action row.
///
/// `.serialized` — same on-disk `__Snapshots__/` directory rule as the
/// rest of the snapshot suites in this folder.
@Suite("AssistantMessage snapshots", .serialized)
@MainActor
struct AssistantMessageSnapshotTests {
    @Test("action row idle — Regenerate enabled")
    func actionRowIdleLight() {
        verify(
            isStreaming: false,
            theme: .light,
            name: "assistant_actions_idle_light"
        )
    }

    @Test("action row streaming — Regenerate greyed")
    func actionRowStreamingLight() {
        verify(
            isStreaming: true,
            theme: .light,
            name: "assistant_actions_streaming_light"
        )
    }

    @Test("action row streaming — Regenerate greyed (dark)")
    func actionRowStreamingDark() {
        verify(
            isStreaming: true,
            theme: .dark,
            name: "assistant_actions_streaming_dark"
        )
    }

    private func verify(
        isStreaming: Bool,
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let view = AssistantMessage(
            thinking: nil,
            thinkingDurationMs: nil,
            text: "Sure — here's a short reply.",
            toolCalls: [],
            verbosity: .simple,
            isStreaming: isStreaming
        )
        .superTheme(.make(theme))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 402)
        .background(SuperTheme.make(theme).background)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .sizeThatFits),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure { Issue.record("\(name): \(failure)") }
    }
}
#endif
