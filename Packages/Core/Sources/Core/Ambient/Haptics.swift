import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Semantic haptic intents whose concrete feel is tuned in `SystemHapticsEngine`.
public enum HapticPattern: Sendable, Equatable {
    case selection
    /// A firmer tap for actions that commit or create data.
    case primary
    case deselection
    /// A light tick per visible word-boundary repaint.
    case streamingTick
    /// A distinct completion buzz when a chat stream ends (clean or error).
    case streamCompleted
}

public protocol HapticsEngine: Sendable {
    /// Silent when disabled or unsupported. MainActor keeps UIKit generators on the main thread.
    @MainActor func play(_ pattern: HapticPattern)
    @MainActor func setEnabled(_ enabled: Bool)
}

public struct NoOpHapticsEngine: HapticsEngine {
    public init() {}
    @MainActor public func play(_ pattern: HapticPattern) {}
    @MainActor public func setEnabled(_ enabled: Bool) {}
}

/// Retains generators because `streamingTick` can fire several times per second.
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

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

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
