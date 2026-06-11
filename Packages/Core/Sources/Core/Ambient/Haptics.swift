import Foundation
import os

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
    /// Play the haptic for `pattern`. Safe to call from any `@MainActor`
    /// context; a no-op when the engine is disabled or the platform has no
    /// Taptic Engine.
    func play(_ pattern: HapticPattern)
    /// Enable or disable all output. Driven by the Settings haptics toggle;
    /// the no-op engine ignores it.
    func setEnabled(_ enabled: Bool)
}

/// Silent engine — the default for previews, tests, and the environment
/// fallback. Lets an unwired call site stay harmless.
public struct NoOpHapticsEngine: HapticsEngine {
    public init() {}
    public func play(_ pattern: HapticPattern) {}
    public func setEnabled(_ enabled: Bool) {}
}

/// Production engine backed by UIKit's feedback generators (the device's
/// Taptic Engine). One instance is owned by the app shell and shared across
/// every applet; an `isEnabled` flag (synced from the persisted Settings
/// toggle) gates all output so the user can silence haptics in-app on top of
/// the OS-level "System Haptics" switch the generators already honor.
///
/// `play(_:)` is `nonisolated` for `Sendable` convenience but must be called
/// on the main thread — every call site (view models, SwiftUI views) is
/// `@MainActor`, so it hops in via `MainActor.assumeIsolated` and fires
/// synchronously. The `isEnabled` flag is guarded by `os_unfair_lock` (the
/// same lock pattern as ``FixedClock``), so the class is `Sendable` without
/// storing any non-`Sendable` UIKit state.
public final class SystemHapticsEngine: HapticsEngine {
    private let enabled = OSAllocatedUnfairLock<Bool>(initialState: true)

    public init() {}

    /// Enable or disable all haptic output. Driven by the Settings toggle.
    public func setEnabled(_ value: Bool) {
        enabled.withLock { $0 = value }
    }

    public func play(_ pattern: HapticPattern) {
        guard enabled.withLock({ $0 }) else { return }
        #if canImport(UIKit)
        MainActor.assumeIsolated {
            Self.fire(pattern)
        }
        #endif
    }

    #if canImport(UIKit)
    /// Concrete pattern → generator mapping. Tuned for "subtle" overall, with
    /// `deselection` softened to read as distinct from `selection`. These
    /// values are the on-device tuning surface.
    @MainActor
    private static func fire(_ pattern: HapticPattern) {
        switch pattern {
        case .selection:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .primary:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .deselection:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.85)
        case .streamingTick:
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
        case .streamCompleted:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
    #endif
}
