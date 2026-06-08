#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Snapshots for the Copy + Regenerate action row beneath
/// ``AssistantMessage``. The interesting visual state added by this PR is
/// the `isStreaming: true` form where Regenerate dims to 40% opacity
/// while Copy stays at full opacity. Pins both states (idle, streaming)
/// across all three themes (light, dark, sepia) plus one Dynamic Type
/// XXL variant on the new disabled state — the cell most likely to
/// regress on a future tweak. Matches the codebase coverage matrix
/// (`light/dark/sepia × default + at-least-one XXL`).
///
/// Wider `MessageList` baselines already cover thinking / tool-call /
/// markdown surfaces, so this suite focuses narrowly on the action row.
///
/// `.serialized` — snapshot baselines are read/written per-test against
/// the same on-disk `__Snapshots__/AssistantMessageSnapshotTests/`
/// directory. Parallel execution races on the PNG files (TOCTOU), not on
/// any async behavior in the code under test — serialization is the
/// right tool here. Matches every other snapshot suite in this folder;
/// the codebase-wide convention is intentional (see
/// `MemoryUpdatedPillSnapshotTests` for the canonical justification).
///
/// Reduce Motion is not recorded as a separate variant: the action row
/// is a static `HStack` of two icon buttons with no `withAnimation` and
/// no `.animation(...)` modifier in the view body. The animation that
/// the disabled-state guards (greyed Regenerate during streaming) lives
/// on the parent `ChatScreen`'s overlay-transition, not in this view —
/// so steady-state frames here are pixel-identical regardless of
/// `accessibilityReduceMotion`.
@Suite("AssistantMessage snapshots", .serialized)
@MainActor
struct AssistantMessageSnapshotTests {
    /// Register the bundled fonts so this suite produces correct baselines even
    /// when run in isolation (other snapshot suites do this too; registration is
    /// process-wide + idempotent, so the existing baselines are unaffected).
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
        // Sub-pixel-tolerant: the XXL variant renders the pill's small text at
        // a large scale on a `.sizeThatFits` (variable-height) canvas, the most
        // antialiasing-fragile combination in this suite. The baseline matches
        // exactly locally on CI's trio; this absorbs only the cross-runner
        // antialiasing drift the default exact compare flags (a structural
        // regression > ~3% perceptual still fails). See AGENTS.md §Testing 5.
        verify(
            isStreaming: false, theme: .vellumLight, dynamicType: .xxLarge,
            sources: Self.sampleSources, precision: 0.99, perceptualPrecision: 0.97,
            name: "assistant_with_sources_light_xxl"
        )
    }

    // Note: a snapshot of the grounded-Gemini state with the Search-Suggestions
    // strip is intentionally NOT included. The strip is a live `WKWebView`, which
    // never signals snapshot-readiness synchronously — swift-snapshot-testing
    // hits "Exceeded timeout waiting for snapshot" rather than producing a
    // deterministic image (the async-load / separate-render-process limitation
    // documented in the web-search spec §0 #8). The strip is covered instead by
    // `GeminiSearchSuggestionsTests` (height clamp + navigation policy) +
    // `ChatScreenViewModelProjectionTests` (the HTML reaches the row) + manual
    // render. The conditional that mounts it is inert when the HTML is nil, so
    // the baselines above are unaffected.

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

        let failure = verifySnapshot(
            of: view,
            as: .image(precision: precision, perceptualPrecision: perceptualPrecision, layout: .sizeThatFits),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure { Issue.record("\(name): \(failure)") }
    }
}
#endif
