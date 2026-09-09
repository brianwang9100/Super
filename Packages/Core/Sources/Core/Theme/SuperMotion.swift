import SwiftUI

/// Shared motion tokens. Each transition concern owns one animation so
/// concurrent animators do not race on the same property.
public enum SuperMotion {
    public static let snap: Animation = .timingCurve(0.34, 1.4, 0.5, 1, duration: 0.38)

    public static let reducedMotion: Animation = .easeInOut(duration: 0.2)

    /// Avoids spring overshoot against keyboard movement. Pass nil under Reduce Motion.
    public static let keyboardGlide: Animation = .smooth(duration: 0.25)

    public static let press: Animation = .spring(response: 0.28, dampingFraction: 0.68)

    /// No overshoot on frequently toggled chrome; use reducedMotion for that setting.
    public static let chromeReveal: Animation = .smooth(duration: 0.4)

    /// Longer than reveal because the visible portion exits before the animation finishes.
    public static let chromeHide: Animation = .smooth(duration: 0.6)

    public static func chrome(hiding: Bool, reduceMotion: Bool) -> Animation {
        guard !reduceMotion else { return reducedMotion }
        return hiding ? chromeHide : chromeReveal
    }

    public static func transition(reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedMotion : snap
    }
}
