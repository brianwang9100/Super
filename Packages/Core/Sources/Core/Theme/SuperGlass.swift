import Foundation
import SwiftUI

/// A Liquid Glass morph identity — the `glassEffectID(_:in:)` inputs bundled
/// into one value so a `SuperGlass` caller passes a single `morph:` argument.
/// Two glass surfaces that carry the same `id` in the same `namespace` (inside
/// one `GlassEffectContainer`) morph into each other when one appears or
/// disappears under an animated transaction. String ids are `Hashable &
/// Sendable`, which is all `glassEffectID` requires.
public struct GlassMorphID {
    let id: String
    let namespace: Namespace.ID

    public init(_ id: String, in namespace: Namespace.ID) {
        self.id = id
        self.namespace = namespace
    }
}

/// Theme-tinted Liquid Glass helpers — the single owner of how Super's nav
/// chrome adopts iOS 26 glass, the way `SuperTypography` owns font-face
/// resolution and `SuperTheme` owns color. Every glass control routes through
/// these so the per-theme tint (especially Sepia's warmth) is decided once,
/// not copied across call sites.
///
/// Glass tracks the system light/dark scheme and samples the content behind it;
/// the `glassTint` from the active `SuperTheme` biases that frosted material
/// toward the theme's character.
///
/// **Hit-testing.** `.glassEffect` collapses the host view's hit region to its
/// content's intrinsic size (the glyph), so a framed 44pt glass button would
/// only respond to taps on the tiny glyph and ignore the rest of the circle
/// (this is what broke the hamburger). `superGlassButton` therefore re-asserts
/// the full `shape` as the control's `contentShape` so the whole button is
/// tappable.
public extension View {
    /// Apply interactive theme-tinted glass to a tappable control, clipped to
    /// `shape` (defaults to a circle for the standard round nav buttons).
    /// Replaces the old fill + border + drop-shadow chrome — glass supplies its
    /// own edge and elevation, so callers should drop those first. Restores the
    /// full-`shape` hit region (see the type note above). Pass `morph` to give
    /// the control a Liquid Glass identity so it morphs into a sibling sharing
    /// the same id when it enters or leaves the hierarchy (see `GlassMorphID`).
    func superGlassButton(
        in shape: some Shape = Circle(),
        morph: GlassMorphID? = nil
    ) -> some View {
        modifier(SuperGlassModifier(shape: shape, interactive: true, morph: morph))
    }

    /// Apply theme-tinted glass to a passive *inline* surface — the nav bar's
    /// book/translation pill and selection pill — clipped to `shape`. Use the
    /// frosted `.regular` glass these produce — never clear glass — so text over
    /// the surface stays legible. Non-interactive so the inner segment buttons
    /// keep their own taps. Pass `morph` to give the surface a Liquid Glass
    /// identity for cross-state morphing (see `GlassMorphID`).
    func superGlassSurface(
        in shape: some Shape,
        morph: GlassMorphID? = nil
    ) -> some View {
        modifier(SuperGlassModifier(shape: shape, interactive: false, morph: morph))
    }
}

/// Reads the active theme's `glassTint` and applies `.glassEffect` so the tint
/// decision lives in one place. Generic over `Shape` so callers keep their own
/// `Circle` / `Capsule` / `RoundedRectangle` clip.
///
/// **Snapshot caveat.** Liquid Glass is composited by the render server and
/// captures as a fully transparent image in offscreen snapshot tests — a
/// documented Apple limitation, not a library bug (pointfreeco/swift-snapshot-testing
/// discussion #1031; the maintainer: *"just how Apple's tools work"*). Capturing
/// it would require a host-app target plus on-screen `drawHierarchyInKeyWindow`,
/// which taxes every CI run and *still* may mis-record a tinted glass as grey
/// (issue #1019). So inside a test process we render a deterministic solid
/// stand-in instead: the suites keep covering layout (sizing, composition,
/// the dropped accent fills) while the real glass is verified on-device. The
/// shipping app never links XCTest, so it always gets true glass.
private struct SuperGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.superTheme) private var theme

    let shape: S
    let interactive: Bool
    let morph: GlassMorphID?

    @ViewBuilder
    func body(content: Content) -> some View {
        // Buttons re-assert `shape` as the hit region (glass collapses it to the
        // glyph); passive surfaces must not, or they'd swallow their own inner
        // controls' taps (e.g. the book/translation pill's two segments).
        if interactive {
            glassed(content).contentShape(shape)
        } else {
            glassed(content)
        }
    }

    @ViewBuilder
    private func glassed(_ content: Content) -> some View {
        if Self.usesSolidFallback {
            // No `glassEffectID` here: it's meaningful only alongside a real
            // glass effect inside a container, and the morph it drives is
            // invisible to offscreen snapshots anyway.
            content
                .background(shape.fill(theme.backgroundRaised))
                .overlay(shape.stroke(theme.borderFaint, lineWidth: 0.5))
        } else {
            morphed(
                content.glassEffect(
                    interactive
                        ? Glass.regular.tint(theme.glassTint).interactive()
                        : Glass.regular.tint(theme.glassTint),
                    in: shape
                )
            )
        }
    }

    /// Tags the glassed content with its morph identity when one was supplied,
    /// so siblings sharing the id morph into each other across hierarchy changes.
    @ViewBuilder
    private func morphed(_ content: some View) -> some View {
        if let morph {
            content.glassEffectID(morph.id, in: morph.namespace)
        } else {
            content
        }
    }

    /// True when running inside an XCTest-hosted (or swift-testing) bundle,
    /// detected by XCTest being linked. The shipping app does not link XCTest,
    /// so this is `false` there and real glass renders.
    private static var usesSolidFallback: Bool {
        NSClassFromString("XCTestCase") != nil
    }
}
