#if canImport(UIKit)
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
    private let models: [ModelPill.Option] = [
        .init(id: "gpt-4o", displayName: "GPT-4o", maxContextTokens: 128_000),
    ]

    @Test("empty composer in light theme")
    func emptyLight() {
        verify(text: "", isStreaming: false, theme: .light, name: "composer_empty_light")
    }

    @Test("empty composer in dark theme")
    func emptyDark() {
        verify(text: "", isStreaming: false, theme: .dark, name: "composer_empty_dark")
    }

    @Test("empty composer in sepia theme")
    func emptySepia() {
        verify(text: "", isStreaming: false, theme: .sepia, name: "composer_empty_sepia")
    }

    @Test("typed composer flips to send")
    func typedFlipsToSend() {
        verify(text: "Hello world", isStreaming: false, theme: .light, name: "composer_typed_light")
    }

    @Test("streaming shows stop")
    func streamingShowsStop() {
        verify(text: "", isStreaming: true, theme: .light, name: "composer_streaming_light")
    }

    @Test("near-max context fills meter")
    func nearMaxContext() {
        let function = #function
        let view = ChatComposer(
            text: .constant(""),
            isStreaming: false,
            modelOptions: models,
            selectedModelId: "gpt-4o",
            onSelectModel: { _ in },
            verbosity: .verbose,
            onSelectVerbosity: { _ in },
            usedTokens: 120_000,
            maxTokens: 128_000,
            onSubmit: { _ in }
        )
        .superTheme(.make(.light))
        .frame(width: 402)
        recordOrCompare(view: view, name: "composer_near_max_light", function: function)
    }

    @Test("dynamic type XXL light")
    func dynamicTypeXXL() {
        let function = #function
        let view = ChatComposer(
            text: .constant("Hello world"),
            isStreaming: false,
            modelOptions: models,
            selectedModelId: "gpt-4o",
            onSelectModel: { _ in },
            verbosity: .verbose,
            onSelectVerbosity: { _ in },
            usedTokens: 1_200,
            maxTokens: 128_000,
            onSubmit: { _ in }
        )
        .superTheme(.make(.light))
        .dynamicTypeSize(.xxLarge)
        .frame(width: 402)
        recordOrCompare(view: view, name: "composer_typed_light_xxl", function: function)
    }

    private func verify(
        text: String,
        isStreaming: Bool,
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let view = ChatComposer(
            text: .constant(text),
            isStreaming: isStreaming,
            modelOptions: models,
            selectedModelId: "gpt-4o",
            onSelectModel: { _ in },
            verbosity: .verbose,
            onSelectVerbosity: { _ in },
            usedTokens: 1_200,
            maxTokens: 128_000,
            onSubmit: { _ in }
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
#endif
