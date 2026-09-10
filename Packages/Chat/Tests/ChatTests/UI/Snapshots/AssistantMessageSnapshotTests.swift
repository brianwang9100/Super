#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Chat

@Suite("AssistantMessage snapshots", .serialized)
@MainActor
struct AssistantMessageSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("action row idle — Regenerate enabled (light)")
    func actionRowIdleLight() {
        verify(
            isStreaming: false,
            theme: .vellumLight,
            name: "assistant_actions_idle_light"
        )
    }

    @Test("action row idle — Regenerate enabled (dark)")
    func actionRowIdleDark() {
        verify(
            isStreaming: false,
            theme: .vellumDark,
            name: "assistant_actions_idle_dark"
        )
    }

    @Test("action row streaming — Regenerate greyed (light)")
    func actionRowStreamingLight() {
        verify(
            isStreaming: true,
            theme: .vellumLight,
            name: "assistant_actions_streaming_light"
        )
    }

    @Test("action row streaming — Regenerate greyed (dark)")
    func actionRowStreamingDark() {
        verify(
            isStreaming: true,
            theme: .vellumDark,
            name: "assistant_actions_streaming_dark"
        )
    }

    @Test("action row streaming — Regenerate greyed at Dynamic Type XXL")
    func actionRowStreamingXXL() {
        verify(
            isStreaming: true,
            theme: .vellumLight,
            dynamicType: .xxLarge,
            name: "assistant_actions_streaming_light_xxl"
        )
    }

    @Test("grounded answer with the sources pill below the text (light)")
    func withSourcesLight() {
        verify(isStreaming: false, theme: .vellumLight, sources: Self.sampleSources, name: "assistant_with_sources_light")
    }

    @Test("grounded answer with the sources pill below the text (dark)")
    func withSourcesDark() {
        verify(isStreaming: false, theme: .vellumDark, sources: Self.sampleSources, name: "assistant_with_sources_dark")
    }

    @Test("grounded answer with the sources pill, Dynamic Type XXL")
    func withSourcesXXL() {
        // Variable-height XXL text needs tolerance for cross-runner antialiasing drift.
        verify(
            isStreaming: false, theme: .vellumLight, dynamicType: .xxLarge,
            sources: Self.sampleSources, precision: 0.99, perceptualPrecision: 0.97,
            name: "assistant_with_sources_light_xxl"
        )
    }

    // WKWebView has no synchronous snapshot-readiness signal. Search HTML is
    // covered by policy and projection tests rather than this static fixture.

    private static let sampleSources: [SourceCitationPillModel] = [
        SourceCitationPillModel(id: "1", title: "Perseverance confirms subsurface water ice", host: "nasa.gov", url: URL(string: "https://www.nasa.gov/mars")!),
        SourceCitationPillModel(id: "2", title: "Mars rover relays new imagery", host: "space.com", url: URL(string: "https://www.space.com/rover")!),
    ]

    private func verify(
        isStreaming: Bool,
        theme: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        sources: [SourceCitationPillModel] = [],
        precision: Float = 1,
        perceptualPrecision: Float = 1,
        name: String,
        function: String = #function
    ) {
        let view = AssistantMessage(
            thinking: nil,
            thinkingDurationMs: nil,
            text: "Sure — here's a short reply.",
            toolCalls: [],
            sources: sources,
            verbosity: .simple,
            isStreaming: isStreaming
        )
        .superTheme(.make(theme))
        .dynamicTypeSize(dynamicType)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 402)
        .background(SuperTheme.make(theme).background)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(precision: precision, perceptualPrecision: perceptualPrecision, layout: .sizeThatFits),
            named: name,
            testName: function
        )
        if let failure { Issue.record("\(name): \(failure)") }
    }
}
#endif
