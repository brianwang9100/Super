import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// The fixed vocabulary of haptic feedback the app plays. Kept small and
/// semantic (intent, not waveform) so call sites stay readable and the
/// concrete feel can be retuned in one place — ``SystemHapticsEngine``.
public enum HapticPattern: Sendable, Equatable {
    /// A subtle tap for most major actions and selections: submitting a
    /// chat message, tapping the hamburger / a sidebar applet / a sidebar
    /// chat row, selecting a Bible verse, and the bulk of glass controls.
    case selection
    /// A firmer, weightier tap for consequential commits that create or
    /// persist something with no immediate follow-up feedback — save a
    /// note/task, create a label, start a new chat, add a model. Sits a
    /// clear step above ``selection`` so a real commit feels distinct from
    /// an ordinary tap.
    case primary
    /// A subtle tap, deliberately distinct from ``selection``, for the
    /// inverse gesture: deselecting a Bible verse or clearing a selection.
    case deselection
    /// A very light tick played per visible word-boundary repaint while a
    /// chat message streams in.
    case streamingTick
    /// A distinct completion buzz when a chat stream ends (clean or error).
    case streamCompleted
}

/// Injectable haptic feedback engine. Production code receives a
/// `HapticsEngine` instead of touching `UIFeedbackGenerator` directly so
/// tests can substitute a recording double and the concrete feel lives in
/// one place. Mirrors the ``Clock`` / ``IDGenerator`` ambient pattern.
public protocol HapticsEngine: Sendable {
    /// Play the haptic for `pattern` — a no-op when the engine is disabled or
    /// the platform has no Taptic Engine. `@MainActor`-isolated: UIKit's
    /// feedback generators must run on the main thread, so requiring it here
    /// turns an off-main call into a compile error rather than a runtime trap.
    @MainActor func play(_ pattern: HapticPattern)
    /// Enable or disable all output. Driven by the Settings haptics toggle;
    /// the no-op engine ignores it.
    @MainActor func setEnabled(_ enabled: Bool)
}

/// Silent engine — the default for previews, tests, and the environment
/// fallback. Lets an unwired call site stay harmless.
public struct NoOpHapticsEngine: HapticsEngine {
    public init() {}
    @MainActor public func play(_ pattern: HapticPattern) {}
    @MainActor public func setEnabled(_ enabled: Bool) {}
}

/// Production engine backed by UIKit's feedback generators (the device's
/// Taptic Engine). One instance is owned by the app shell and shared across
/// every applet; an `isEnabled` flag (synced from the persisted Settings
/// toggle) gates all output so the user can silence haptics in-app on top of
/// the OS-level "System Haptics" switch the generators already honor.
///
/// `@MainActor`-isolated (its `play`/`setEnabled` must touch UIKit on the main
/// thread). The generators are retained and reused rather than allocated per
/// call — the per-word ``HapticPattern/streamingTick`` fires many times a
/// second, and a retained generator also keeps the Taptic engine warmer.
@MainActor
public final class SystemHapticsEngine: HapticsEngine {
    private var isEnabled = true

    #if canImport(UIKit)
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
    private let softImpact = UIImpactFeedbackGenerator(style: .soft)
    private let notification = UINotificationFeedbackGenerator()
    #endif

    public init() {}

    /// Enable or disable all haptic output. Driven by the Settings toggle.
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    /// Concrete pattern → generator mapping. Tuned for "subtle" overall, with
    /// `deselection` softened to read as distinct from `selection`. These
    /// values are the on-device tuning surface.
    public func play(_ pattern: HapticPattern) {
        guard isEnabled else { return }
        #if canImport(UIKit)
        switch pattern {
        case .selection:
            mediumImpact.impactOccurred()
        case .primary:
            heavyImpact.impactOccurred()
        case .deselection:
            softImpact.impactOccurred(intensity: 0.85)
        case .streamingTick:
            lightImpact.impactOccurred(intensity: 0.5)
        case .streamCompleted:
            notification.notificationOccurred(.success)
        }
        #endif
    }
}
