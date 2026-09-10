import Foundation

/// Optional preflight probe before narration acquires the audio session. Implement
/// outside Bible to avoid importing the applet that owns microphone capture.
/// A nil coordinator leaves this service-level check inactive.
public protocol NarrationAudioCoordinator: AnyObject, Sendable {
    /// True while external capture owns audio; queried synchronously once per startSpeaking.
    func isVoiceInputActive() -> Bool
}

public final class InactiveNarrationAudioCoordinator: NarrationAudioCoordinator {
    public init() {}
    public func isVoiceInputActive() -> Bool { false }
}
