#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Snapshot matrix for `ChatComposer`: empty (mic), typed (send),
/// streaming (cancel), each across the three themes for a representative
/// state. Pinned width 402pt mirrors the design's iPhone reference frame.
@Suite("ChatComposer snapshots", .serialized)
@MainActor
struct ChatComposerSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    private let models: [ModelPill.Option] = [
        .init(id: "gpt-4o", displayName: "GPT-4o", maxContextTokens: 128_000),
    ]

    @Test("empty composer in light theme")
    func emptyLight() {
        verify(text: "", isStreaming: false, theme: .vellumLight, name: "composer_empty_light")
    }

    @Test("empty composer in dark theme")
    func emptyDark() {
        verify(text: "", isStreaming: false, theme: .vellumDark, name: "composer_empty_dark")
    }

    @Test("empty composer in sepia theme")
    func emptySepia() {
        verify(text: "", isStreaming: false, theme: .sepiaLight, name: "composer_empty_sepia")
    }

    @Test("typed composer flips to send")
    func typedFlipsToSend() {
        verify(text: "Hello world", isStreaming: false, theme: .vellumLight, name: "composer_typed_light")
    }

    @Test("streaming shows stop")
    func streamingShowsStop() {
        verify(text: "", isStreaming: true, theme: .vellumLight, name: "composer_streaming_light")
    }

    @Test("near-max context fills meter")
    func nearMaxContext() {
        let function = #function
        let view = FocusHostingChatComposer(
            text: "",
            isStreaming: false,
            modelOptions: models,
            selectedModelId: "gpt-4o",
            usedTokens: 120_000,
            maxTokens: 128_000
        )
        .superTheme(.make(.vellumLight))
        .frame(width: 402)
        recordOrCompare(view: view, name: "composer_near_max_light", function: function)
    }

    // MARK: - M11 voice-input states

    @Test("recording state in light theme")
    func recordingLight() {
        let function = #function
        let view = makeComposer(text: "", isRecording: true, theme: .vellumLight)
        recordOrCompare(view: view, name: "composer_recording_light", function: function)
    }

    @Test("recording state in dark theme")
    func recordingDark() {
        let function = #function
        let view = makeComposer(text: "", isRecording: true, theme: .vellumDark)
        recordOrCompare(view: view, name: "composer_recording_dark", function: function)
    }

    @Test("recording state in sepia theme")
    func recordingSepia() {
        let function = #function
        // Sepia's accent differs from light/dark, so this baseline
        // catches accent-fill regressions on the recording stop button
        // that the light/dark variants would miss. Per Chat CLAUDE.md
        // the per-state matrix is light/dark/sepia × default/Dynamic Type XXL.
        let view = makeComposer(text: "", isRecording: true, theme: .sepiaLight)
        recordOrCompare(view: view, name: "composer_recording_sepia", function: function)
    }

    @Test("recording state with reduce motion suppresses the pulse overlay")
    func recordingReduceMotion() {
        let function = #function
        // SwiftUI's `\.accessibilityReduceMotion` env value is read-only,
        // so we route through the composer's `\.chatComposerReduceMotionOverride`
        // shim that defaults to nil and falls back to the system value
        // in production. Lets us pin the no-pulse rendering.
        let view = makeComposer(text: "", isRecording: true, theme: .vellumLight)
            .environment(\.chatComposerReduceMotionOverride, true)
        recordOrCompare(view: view, name: "composer_recording_reduce_motion", function: function)
    }

    @Test("mic button rendered dimmed when on-device recognition is unavailable")
    func micUnavailableLight() {
        let function = #function
        let view = makeComposer(text: "", isRecording: false, isMicAvailable: false, theme: .vellumLight)
        recordOrCompare(view: view, name: "composer_mic_unavailable_light", function: function)
    }

    @Test("dimmed mic in sepia theme")
    func micUnavailableSepia() {
        let function = #function
        let view = makeComposer(text: "", isRecording: false, isMicAvailable: false, theme: .sepiaLight)
        recordOrCompare(view: view, name: "composer_mic_unavailable_sepia", function: function)
    }

    @Test("recording state at dynamic type XXL")
    func recordingXXL() {
        let function = #function
        let view = makeComposer(text: "", isRecording: true, theme: .vellumLight)
            .dynamicTypeSize(.xxLarge)
        recordOrCompare(view: view, name: "composer_recording_xxl", function: function)
    }

    private func makeComposer(
        text: String,
        isRecording: Bool,
        isMicAvailable: Bool = true,
        theme: SuperTheme.Identifier
    ) -> some View {
        FocusHostingChatComposer(
            text: text,
            isStreaming: false,
            modelOptions: models,
            selectedModelId: "gpt-4o",
            usedTokens: 1_200,
            maxTokens: 128_000,
            isRecording: isRecording,
            isMicAvailable: isMicAvailable
        )
        .superTheme(.make(theme))
        .frame(width: 402)
    }

    // MARK: - Pill-mode morph extreme

    @Test("composer at progress 0 renders as the minimized pill")
    func pillModeLight() {
        let function = #function
        let view = FocusHostingChatComposer(
            text: "",
            isStreaming: false,
            modelOptions: models,
            selectedModelId: "gpt-4o",
            usedTokens: 1_200,
            maxTokens: 128_000,
            progress: 0
        )
        .superTheme(.make(.vellumLight))
        .frame(width: 402)
        recordOrCompare(view: view, name: "composer_pill_light", function: function)
    }

    /// Dark variant for the pill extreme — catches regressions where
    /// the lifted-pill shadow or the morphing label color drifts on a
    /// dark palette specifically.
    @Test("composer at progress 0 renders as the minimized pill — dark")
    func pillModeDark() {
        let function = #function
        let view = FocusHostingChatComposer(
            text: "",
            isStreaming: false,
            modelOptions: models,
            selectedModelId: "gpt-4o",
            usedTokens: 1_200,
            maxTokens: 128_000,
            progress: 0
        )
        .superTheme(.make(.vellumDark))
        .frame(width: 402)
        recordOrCompare(view: view, name: "composer_pill_dark", function: function)
    }

    /// Sepia variant for the pill extreme — completes the
    /// light/dark/sepia matrix required by `Packages/Chat/AGENTS.md`
    /// for snapshot tests.
    @Test("composer at progress 0 renders as the minimized pill — sepia")
    func pillModeSepia() {
        let function = #function
        let view = FocusHostingChatComposer(
            text: "",
            isStreaming: false,
            modelOptions: models,
            selectedModelId: "gpt-4o",
            usedTokens: 1_200,
            maxTokens: 128_000,
            progress: 0
        )
        .superTheme(.make(.sepiaLight))
        .frame(width: 402)
        recordOrCompare(view: view, name: "composer_pill_sepia", function: function)
    }

    /// Mid-morph baseline that pins the cross-fade between the pill
    /// label and the editor. Sits inside the editor's [0, 0.2] fade
    /// band — both the label and the editor are partially visible —
    /// and the footer is just starting to appear (≈ progress 0.15 of
    /// its [0.15, 0.45] fade-in). Catches drift in the smoothstep
    /// timings that the two endpoint baselines can't see.
    @Test("composer mid-morph at progress 0.15")
    func midMorphLight() {
        let function = #function
        let view = FocusHostingChatComposer(
            text: "",
            isStreaming: false,
            modelOptions: models,
            selectedModelId: "gpt-4o",
            usedTokens: 1_200,
            maxTokens: 128_000,
            progress: 0.15
        )
        .superTheme(.make(.vellumLight))
        .frame(width: 402)
        recordOrCompare(view: view, name: "composer_mid_morph_light", function: function)
    }

    @Test("dynamic type XXL light")
    func dynamicTypeXXL() {
        let function = #function
        let view = FocusHostingChatComposer(
            text: "Hello world",
            isStreaming: false,
            modelOptions: models,
            selectedModelId: "gpt-4o",
            usedTokens: 1_200,
            maxTokens: 128_000
        )
        .superTheme(.make(.vellumLight))
        .dynamicTypeSize(.xxLarge)
        .frame(width: 402)
        recordOrCompare(view: view, name: "composer_typed_light_xxl", function: function)
    }

    /// Locks the `* appearance.fontScale` wiring on the editor font. At
    /// the default `fontScale == 1.0` the multiplication is a no-op, so
    /// the remaining baselines would stay green if the multiplication
    /// were deleted. Injecting the upper-bound knob proves the editor
    /// actually tracks the slider, mirroring `MessageListSnapshotTests`'
    /// `appearanceScaleMax` precedent.
    @Test("font scale max light")
    func fontScaleMax() {
        let function = #function
        let view = FocusHostingChatComposer(
            text: "Hello world",
            isStreaming: false,
            modelOptions: models,
            selectedModelId: "gpt-4o",
            usedTokens: 1_200,
            maxTokens: 128_000
        )
        .superTheme(.make(.vellumLight))
        .chatAppearance(ChatAppearance(fontScale: 1.20))
        .superTypography(.make(.serif, fontScale: 1.20))
        .frame(width: 402)
        recordOrCompare(view: view, name: "composer_font_scale_max_light", function: function)
    }

    /// Dark-mode counterpart to ``fontScaleMax`` — per AGENTS.md §Testing.3
    /// every new SwiftUI variant needs a light + dark pair. Catches
    /// regressions where the larger editor size interacts with the dark
    /// palette (composer fill, focus border, accent button) in ways the
    /// light baseline misses.
    @Test("font scale max dark")
    func fontScaleMaxDark() {
        let function = #function
        let view = FocusHostingChatComposer(
            text: "Hello world",
            isStreaming: false,
            modelOptions: models,
            selectedModelId: "gpt-4o",
            usedTokens: 1_200,
            maxTokens: 128_000
        )
        .superTheme(.make(.vellumDark))
        .chatAppearance(ChatAppearance(fontScale: 1.20))
        .superTypography(.make(.serif, fontScale: 1.20))
        .frame(width: 402)
        recordOrCompare(view: view, name: "composer_font_scale_max_dark", function: function)
    }

    /// Sepia counterpart to ``fontScaleMax`` — Chat AGENTS.md's snapshot
    /// matrix is `light/dark/sepia × default/Dynamic Type XXL` and every
    /// other composer baseline covers the warm sepia palette. Catches
    /// regressions where the scaled editor interacts with sepia's
    /// composer fill, focus border, and accent button specifically.
    @Test("font scale max sepia")
    func fontScaleMaxSepia() {
        let function = #function
        let view = FocusHostingChatComposer(
            text: "Hello world",
            isStreaming: false,
            modelOptions: models,
            selectedModelId: "gpt-4o",
            usedTokens: 1_200,
            maxTokens: 128_000
        )
        .superTheme(.make(.sepiaLight))
        .chatAppearance(ChatAppearance(fontScale: 1.20))
        .superTypography(.make(.serif, fontScale: 1.20))
        .frame(width: 402)
        recordOrCompare(view: view, name: "composer_font_scale_max_sepia", function: function)
    }

    /// The extreme upper-bound: maxed font slider stacked on top of XXL
    /// Dynamic Type. `@ScaledMetric(relativeTo: .subheadline)` already
    /// scales `editorBase` from 17 → ~20pt at XXL; the further `× 1.20`
    /// from the slider pushes the rendered editor to ~24pt — the largest
    /// the user can reach. Locks the corner case where the editor row
    /// might push past the `lineLimit(1...6)` clamp or compress the
    /// token-count badge / send-button slot on the footer.
    @Test("font scale max at dynamic type XXL")
    func fontScaleMaxXXL() {
        let function = #function
        let view = FocusHostingChatComposer(
            text: "Hello world",
            isStreaming: false,
            modelOptions: models,
            selectedModelId: "gpt-4o",
            usedTokens: 1_200,
            maxTokens: 128_000
        )
        .superTheme(.make(.vellumLight))
        .chatAppearance(ChatAppearance(fontScale: 1.20))
        .superTypography(.make(.serif, fontScale: 1.20))
        .dynamicTypeSize(.xxLarge)
        .frame(width: 402)
        recordOrCompare(view: view, name: "composer_font_scale_max_light_xxl", function: function)
    }

    // MARK: - Verse reference pills

    private func composerWithReferences(
        _ references: [VerseReferencePillModel],
        text: String = "",
        theme: SuperTheme.Identifier
    ) -> some View {
        FocusHostingChatComposer(
            text: text,
            isStreaming: false,
            modelOptions: models,
            selectedModelId: "gpt-4o",
            usedTokens: 1_200,
            maxTokens: 128_000,
            references: references
        )
        .superTheme(.make(theme))
        .frame(width: 402)
    }

    @Test("composer with one verse pill — light")
    func oneReferencePillLight() {
        let function = #function
        let view = composerWithReferences(
            [VerseReferencePillModel(id: "r1", label: "John 3:16-17 (WEB)")],
            text: "What does this mean?",
            theme: .vellumLight
        )
        recordOrCompare(view: view, name: "composer_reference_pill_light", function: function)
    }

    @Test("composer with one verse pill — dark")
    func oneReferencePillDark() {
        let function = #function
        let view = composerWithReferences(
            [VerseReferencePillModel(id: "r1", label: "John 3:16-17 (WEB)")],
            text: "What does this mean?",
            theme: .vellumDark
        )
        recordOrCompare(view: view, name: "composer_reference_pill_dark", function: function)
    }

    @Test("composer with multiple verse pills — light")
    func multipleReferencePillsLight() {
        let function = #function
        let view = composerWithReferences(
            [
                VerseReferencePillModel(id: "r1", label: "John 3:16 (WEB)"),
                VerseReferencePillModel(id: "r2", label: "Romans 8:28 (WEB)"),
            ],
            theme: .vellumLight
        )
        recordOrCompare(view: view, name: "composer_reference_pills_multiple_light", function: function)
    }

    @Test("composer with one verse pill at Dynamic Type XXL — light")
    func oneReferencePillXXL() {
        let function = #function
        let view = composerWithReferences(
            [VerseReferencePillModel(id: "r1", label: "John 3:16-17 (WEB)")],
            text: "What does this mean?",
            theme: .vellumLight
        )
        .dynamicTypeSize(.xxLarge)
        recordOrCompare(view: view, name: "composer_reference_pill_light_xxl", function: function)
    }

    private func verify(
        text: String,
        isStreaming: Bool,
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let view = FocusHostingChatComposer(
            text: text,
            isStreaming: isStreaming,
            modelOptions: models,
            selectedModelId: "gpt-4o",
            usedTokens: 1_200,
            maxTokens: 128_000
        )
        .superTheme(.make(theme))
        .frame(width: 402)
        recordOrCompare(view: view, name: name, function: function)
    }

    private func recordOrCompare<V: View>(
        view: V,
        name: String,
        function: String = #function
    ) {
        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .sizeThatFits),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}

/// Test-only wrapper that owns the composer's `@FocusState` so snapshot
/// tests can construct `ChatComposer` (which now takes a
/// `FocusState<Bool>.Binding`) without each call site declaring its own
/// focus property. The state stays `false` for the lifetime of the
/// snapshot render — baselines capture the unfocused composer, matching
/// the pre-change appearance.
@MainActor
private struct FocusHostingChatComposer: View {
    let text: String
    let isStreaming: Bool
    let modelOptions: [ModelPill.Option]
    let selectedModelId: String?
    let usedTokens: Int
    let maxTokens: Int
    var isRecording: Bool = false
    var isMicAvailable: Bool = true
    var progress: Double = 1
    var references: [VerseReferencePillModel] = []
    @FocusState private var isFocused: Bool

    var body: some View {
        ChatComposer(
            text: .constant(text),
            isFocused: $isFocused,
            isStreaming: isStreaming,
            modelOptions: modelOptions,
            selectedModelId: selectedModelId,
            onSelectModel: { _ in },
            usedTokens: usedTokens,
            maxTokens: maxTokens,
            onSubmit: { _ in },
            isRecording: isRecording,
            isMicAvailable: isMicAvailable,
            progress: progress,
            references: references
        )
    }
}
#endif
