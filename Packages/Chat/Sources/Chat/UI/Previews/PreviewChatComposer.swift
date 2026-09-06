#if DEBUG && canImport(UIKit)
import Core
import SwiftUI

/// Deterministic, unfocused composer fixture shared by Xcode previews and the pilot renderer.
/// Kept in Chat so internal environment seams need no public access or test-target import.
struct PreviewChatComposer: View {
    let text: String
    let theme: SuperTheme.Identifier
    var isStreaming = false
    var isRecording = false
    var isMicAvailable = true
    var usedTokens = 1_200
    var progress: Double = 1
    var fontScale: Double = 1
    var dynamicType: DynamicTypeSize = .large
    var reduceMotion: Bool?
    var references: [VerseReferencePillModel] = []
    @FocusState private var isFocused: Bool

    var body: some View {
        Core.registerBundledFonts()
        return ChatComposer(
            text: .constant(text),
            isFocused: $isFocused,
            isStreaming: isStreaming,
            modelOptions: [.init(id: "gpt-4o", displayName: "GPT-4o", maxContextTokens: 128_000)],
            selectedModelId: "gpt-4o",
            onSelectModel: { _ in },
            usedTokens: usedTokens,
            maxTokens: 128_000,
            onSubmit: { _ in },
            isRecording: isRecording,
            isMicAvailable: isMicAvailable,
            progress: progress,
            references: references
        )
        .superTheme(.make(theme))
        .chatAppearance(ChatAppearance(fontScale: fontScale))
        .superTypography(.make(.serif, fontScale: fontScale))
        .dynamicTypeSize(dynamicType)
        .environment(\.chatComposerReduceMotionOverride, reduceMotion)
        .environment(\.chatComposerPreviewPulse, .init(progress: 0))
        .frame(width: 402)
        // Point-Free's legacy hosting controller supplies a white backing surface,
        // including for dark-themed content. Make that renderer assumption explicit.
        .background(.white)
    }
}
#endif
