import Foundation

/// Probe ``NarrationService`` consults before acquiring the audio session,
/// so a `Narrate` tap during an active voice-input session refuses cleanly
/// (yielding `.failed(.preemptedByVoiceInput)`) instead of fighting the
/// mic for the AVAudioSession category.
///
/// The probe is the cross-applet seam: Bible never imports Chat. A
/// concrete shell-side adapter that bridges Chat's `VoiceInputController`
/// state into this protocol is **not yet wired** — `BibleApplet` currently
/// constructs `AVSpeechSynthesizerNarrationService(coordinator: nil)`, so
/// the preemption check is a no-op in production. The arbitration ships in
/// a follow-up PR that lands the adapter in `AppBootstrap`; until then,
/// users who tap Narrate while dictating in Chat will see the two audio
/// sessions race for the category. The follow-up requires touching Chat +
/// Shell + Core surfaces and is out of scope for this PR.
public protocol NarrationAudioCoordinator: AnyObject, Sendable {
    /// Returns `true` when an external audio capture session — typically
    /// Chat's voice input — currently holds the audio session. Called
    /// once per `startSpeaking` call, off the main actor.
    func isVoiceInputActive() -> Bool
}

/// Default coordinator used in previews and tests where no voice input
/// exists — always reports the session is free.
public final class InactiveNarrationAudioCoordinator: NarrationAudioCoordinator {
    public init() {}
    public func isVoiceInputActive() -> Bool { false }
}
