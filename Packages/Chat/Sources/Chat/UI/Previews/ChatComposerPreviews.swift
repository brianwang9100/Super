#if DEBUG && canImport(UIKit)
import Core
import SwiftUI

#Preview("composer_typed_light_xxl", traits: .sizeThatFitsLayout) {
    PreviewChatComposer(
        text: "Hello world",
        theme: .vellumLight,
        dynamicType: .xxLarge
    )
}

#Preview("composer_empty_dark", traits: .sizeThatFitsLayout) {
    PreviewChatComposer(
        text: "",
        theme: .vellumDark
    )
}

#Preview("composer_empty_light", traits: .sizeThatFitsLayout) {
    PreviewChatComposer(
        text: "",
        theme: .vellumLight
    )
}

#Preview("composer_font_scale_max_light", traits: .sizeThatFitsLayout) {
    PreviewChatComposer(
        text: "Hello world",
        theme: .vellumLight,
        fontScale: 1.2
    )
}

#Preview("composer_font_scale_max_dark", traits: .sizeThatFitsLayout) {
    PreviewChatComposer(
        text: "Hello world",
        theme: .vellumDark,
        fontScale: 1.2
    )
}

#Preview("composer_font_scale_max_light_xxl", traits: .sizeThatFitsLayout) {
    PreviewChatComposer(
        text: "Hello world",
        theme: .vellumLight,
        fontScale: 1.2,
        dynamicType: .xxLarge
    )
}

#Preview("composer_mic_unavailable_light", traits: .sizeThatFitsLayout) {
    PreviewChatComposer(
        text: "",
        theme: .vellumLight,
        isMicAvailable: false
    )
}

#Preview("composer_mid_morph_light", traits: .sizeThatFitsLayout) {
    PreviewChatComposer(
        text: "",
        theme: .vellumLight,
        progress: 0.15
    )
}

#Preview("composer_reference_pills_multiple_light", traits: .sizeThatFitsLayout) {
    PreviewChatComposer(
        text: "",
        theme: .vellumLight,
        references: [.init(id: "r1", label: "John 3:16 (WEB)"), .init(id: "r2", label: "Romans 8:28 (WEB)")]
    )
}

#Preview("composer_near_max_light", traits: .sizeThatFitsLayout) {
    PreviewChatComposer(
        text: "",
        theme: .vellumLight,
        usedTokens: 120000
    )
}

#Preview("composer_reference_pill_dark", traits: .sizeThatFitsLayout) {
    PreviewChatComposer(
        text: "What does this mean?",
        theme: .vellumDark,
        references: [.init(id: "r1", label: "John 3:16-17 (WEB)")]
    )
}

#Preview("composer_reference_pill_light", traits: .sizeThatFitsLayout) {
    PreviewChatComposer(
        text: "What does this mean?",
        theme: .vellumLight,
        references: [.init(id: "r1", label: "John 3:16-17 (WEB)")]
    )
}

#Preview("composer_reference_pill_light_xxl", traits: .sizeThatFitsLayout) {
    PreviewChatComposer(
        text: "What does this mean?",
        theme: .vellumLight,
        dynamicType: .xxLarge,
        references: [.init(id: "r1", label: "John 3:16-17 (WEB)")]
    )
}

#Preview("composer_pill_dark", traits: .sizeThatFitsLayout) {
    PreviewChatComposer(
        text: "",
        theme: .vellumDark,
        progress: 0
    )
}

#Preview("composer_pill_light", traits: .sizeThatFitsLayout) {
    PreviewChatComposer(
        text: "",
        theme: .vellumLight,
        progress: 0
    )
}

#Preview("composer_recording_dark", traits: .sizeThatFitsLayout) {
    PreviewChatComposer(
        text: "",
        theme: .vellumDark,
        isRecording: true
    )
}

#Preview("composer_recording_light", traits: .sizeThatFitsLayout) {
    PreviewChatComposer(
        text: "",
        theme: .vellumLight,
        isRecording: true
    )
}

#Preview("composer_recording_reduce_motion", traits: .sizeThatFitsLayout) {
    PreviewChatComposer(
        text: "",
        theme: .vellumLight,
        isRecording: true,
        reduceMotion: true
    )
}

#Preview("composer_recording_xxl", traits: .sizeThatFitsLayout) {
    PreviewChatComposer(
        text: "",
        theme: .vellumLight,
        isRecording: true,
        dynamicType: .xxLarge
    )
}

#Preview("composer_streaming_light", traits: .sizeThatFitsLayout) {
    PreviewChatComposer(
        text: "",
        theme: .vellumLight,
        isStreaming: true
    )
}

#Preview("composer_typed_light", traits: .sizeThatFitsLayout) {
    PreviewChatComposer(
        text: "Hello world",
        theme: .vellumLight
    )
}

#endif
