#if DEBUG
import Testing
@testable import Chat

/// The preview phase preserves ring appearance while preventing a repeating capture animation.
@Suite("ChatComposer preview pulse")
struct ChatComposerPreviewPulseTests {
    #if canImport(UIKit)
    @Test @MainActor func recordingPreviewsPinReduceMotion() {
        let ordinary = PreviewChatComposer(text: "", theme: .vellumLight, isRecording: true)
        let reduced = PreviewChatComposer(text: "", theme: .vellumLight, isRecording: true, reduceMotion: true)
        #expect(!ordinary.reduceMotion)
        #expect(reduced.reduceMotion)
    }
    #endif

    @Test func fixedEndpoints() {
        let initial = ChatComposerPreviewPulse(progress: 0)
        #expect(initial.scale == 1)
        #expect(initial.opacity == 0.6)
        let end = ChatComposerPreviewPulse(progress: 1)
        #expect(end.scale == 1.5)
        #expect(end.opacity == 0)
    }

    @Test func clampsInvalidProgress() {
        #expect(ChatComposerPreviewPulse(progress: -1) == ChatComposerPreviewPulse(progress: 0))
        #expect(ChatComposerPreviewPulse(progress: 2) == ChatComposerPreviewPulse(progress: 1))
    }

    @Test func pinnedPhasePreventsAnimationAndNilPreservesLiveBehavior() {
        #expect(ChatComposerPreviewPulse.shouldAnimate(reduceMotion: false, override: nil))
        #expect(!ChatComposerPreviewPulse.shouldAnimate(reduceMotion: true, override: nil))
        let initialAnimates = ChatComposerPreviewPulse.shouldAnimate(
            reduceMotion: false, override: ChatComposerPreviewPulse(progress: 0)
        )
        let finalAnimates = ChatComposerPreviewPulse.shouldAnimate(
            reduceMotion: false, override: ChatComposerPreviewPulse(progress: 1)
        )
        #expect(!initialAnimates)
        #expect(!finalAnimates)
    }
}
#endif
