import SwiftUI

/// Motion (animation) design tokens shared across the Super design system,
/// alongside ``SuperTheme`` (color/surface) and ``SuperFontScale``
/// (typography). Picks one animation per transition concern so two
/// concurrent animators can never race on the same property — the failure
/// mode the chat overlay's snap spring vs. UIKit's keyboard-inset
/// animation produced in PR #65.
///
/// Centralised in Core so additional applets (Bible, Todo, Home) that
/// adopt the same bottom-sheet morph or any analogous spring transition
/// can reach for the same tokens without re-deriving the timing curve.
public enum SuperMotion {
    /// Default snap-to-anchor spring on drag release. Matches the 2026-05-13
    /// design spec — `cubic-bezier(0.34, 1.4, 0.5, 1)` over 380ms. The
    /// overshoot (`y > 1` at the curve's late phase) produces the soft
    /// Apple-style lift on settle.
    public static let snap: Animation = .timingCurve(0.34, 1.4, 0.5, 1, duration: 0.38)

    /// Reduce-Motion fallback — a short crossfade in place of the snap
    /// spring. Used when the system `accessibilityReduceMotion` setting
    /// is on so a vestibular-sensitive user never sees the overshoot.
    public static let reducedMotion: Animation = .easeInOut(duration: 0.2)

    /// Button-press scale spring — a quick, lightly-damped settle used by
    /// ``SuperPressButtonStyle`` for the press feedback on inert glass control
    /// clusters (the Bible action sheet's swatches/tiles), where the built-in
    /// `.interactive()` Liquid Glass glow reads as a flicker on release. Short
    /// enough to feel immediate; just enough give to feel alive.
    public static let press: Animation = .spring(response: 0.28, dampingFraction: 0.68)

    /// Returns the appropriate animation for the current motion
    /// preference. Callers pass the environment's
    /// `\.accessibilityReduceMotion` value; this enum stays
    /// non-View so it can be reused outside SwiftUI bodies.
    public static func transition(reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedMotion : snap
    }
}
