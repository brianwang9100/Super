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
/// these so the per-theme tint (the warm families' warmth, Lapis's cool
/// indigo) is decided once, not copied across call sites.
///
/// Glass tracks the system light/dark scheme and samples the content behind it;
/// the `glassTint` from the active `SuperTheme` biases that frosted material
/// toward the theme's character.
///
/// **Interactive vs. inert glass.** `Glass.interactive()` gives a free liquid
/// press, but in a tight cluster of glass buttons it shows a brief glow flicker
/// as each shape springs back on release (and Apple's `.buttonStyle(.glass)`
/// only tints faintly, while `.glassProminent` flickers the same way). So for
/// dense clusters — the Bible verse action sheet — pass `interactive: false`
/// for a still, strongly-tinted surface and pair the button with
/// ``SuperPressButtonStyle``, which supplies a clean centred press-scale and no
/// glow. Standalone nav chrome keeps the default interactive glass.
///
/// **Hit-testing.** `.glassEffect` collapses the host view's hit region to its
/// content's intrinsic size (the glyph), so a framed 44pt glass button would
/// only respond to taps on the tiny glyph and ignore the rest of the circle
/// (this is what broke the hamburger). `superGlassButton` therefore re-asserts
/// the full `shape` as the control's `contentShape` so the whole button is
/// tappable.
public extension View {
    /// Apply theme-tinted glass to a tappable control, clipped to `shape`
    /// (defaults to a circle for the standard round nav buttons). Replaces the
    /// old fill + border + drop-shadow chrome — glass supplies its own edge and
    /// elevation, so callers should drop those first. Restores the full-`shape`
    /// hit region (see the type note above).
    ///
    /// - Parameters:
    ///   - tint: Biases the frosted material toward this colour instead of the
    ///     theme's `glassTint` — used where the control *is* the colour (the
    ///     Bible highlight swatches) or carries a grouping accent (the AI action
    ///     tiles). `nil` keeps the standard theme tint.
    ///   - interactive: Whether the glass reacts to touch with the built-in
    ///     liquid press. Defaults to `true`. Pass `false` in a dense cluster
    ///     where that press glow-flickers on release, and pair with
    ///     ``SuperPressButtonStyle`` for the press feedback instead.
    ///   - morph: Gives the control a Liquid Glass identity so it morphs into a
    ///     sibling sharing the same id when it enters or leaves the hierarchy
    ///     (see `GlassMorphID`). `nil` for a static control.
    func superGlassButton(
        in shape: some Shape = Circle(),
        tint: Color? = nil,
        interactive: Bool = true,
        morph: GlassMorphID? = nil
    ) -> some View {
        modifier(SuperGlassModifier(
            shape: shape,
            glassInteractive: interactive,
            assertsHitRegion: true,
            tint: tint,
            morph: morph
        ))
    }

    /// Apply theme-**accent**-tinted glass to a call-to-action control — the
    /// send / save (✓) / add (+) buttons. This is the prominent-glass look the
    /// narration sheet's play button established (`superGlassButton(in:tint:)`
    /// biased toward `theme.accent`): the primary action reads as primary
    /// *without* a hard filled-accent disc, while still riding real Liquid
    /// Glass. Pair it with `.foregroundStyle(theme.accentInk)` on the glyph so
    /// the symbol sits legibly on the accent. Neutral nav chrome (close, back,
    /// toolbar controls) stays on ``superGlassButton(in:tint:interactive:morph:)``.
    ///
    /// Kept as a modifier rather than a one-line `superGlassButton(tint:)`
    /// forward so the accent is read from `@Environment(\.superTheme)` here
    /// instead of every call site threading `theme.accent` through.
    func superGlassCTAButton(in shape: some Shape = Circle()) -> some View {
        modifier(SuperGlassCTAModifier(shape: shape))
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
        modifier(SuperGlassModifier(
            shape: shape,
            glassInteractive: false,
            assertsHitRegion: false,
            tint: nil,
            morph: morph
        ))
    }
}

/// Resolves the active theme's `accent` and forwards it to `superGlassButton`
/// as the tint, so `superGlassCTAButton` callers don't each have to read the
/// theme and pass `theme.accent` by hand.
private struct SuperGlassCTAModifier<S: Shape>: ViewModifier {
    @Environment(\.superTheme) private var theme

    let shape: S

    func body(content: Content) -> some View {
        content.superGlassButton(in: shape, tint: theme.accent)
    }
}

/// Press feedback for glass controls that opt out of the built-in
/// `.interactive()` glass press — it scales the whole control on touch with
/// ``SuperMotion/press`` and lets go cleanly, so a tight cluster of glass
/// buttons (the Bible action sheet) stays satisfying to tap without the glow
/// flicker the liquid press shows on release. Apply it to a `Button` whose
/// label *is* the glass surface, so the scale stays centred on the control.
/// Pair with `superGlassButton(in:tint:interactive: false)`.
public struct SuperPressButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        // A nested View so the press animation can read `accessibilityReduceMotion`
        // from the environment (a `ButtonStyle` itself can't hold @Environment).
        PressScale(configuration: configuration)
    }

    private struct PressScale: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let configuration: ButtonStyleConfiguration

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                // Reduce Motion swaps the spring's overshoot for a flat crossfade,
                // per the project's motion policy (see `SuperMotion`).
                .animation(
                    reduceMotion ? SuperMotion.reducedMotion : SuperMotion.press,
                    value: configuration.isPressed
                )
        }
    }
}

/// Groups child glass surfaces into one shared Liquid Glass sampling region so a
/// cluster of glass controls (e.g. the chapter grid) reads as one cohesive field
/// instead of N independently-shadowed pills. Glass samples an area larger than its
/// own bounds and can't sample a neighbouring glass, so a tight grid of separately
/// glassed cells produces overlapping shadow/sampling artifacts; a container gives
/// them a single sampling region with unified lighting and one elevation.
///
/// `spacing` is the proximity threshold at which adjacent glass shapes *merge* into
/// one blob — keep it below the inter-element gap so the children stay visually
/// distinct (pass `0` to share the sampling region without ever merging).
///
/// Mirrors `SuperGlassModifier`'s test story: inside an XCTest-hosted bundle the real
/// `GlassEffectContainer` (like `.glassEffect`) captures as transparent in offscreen
/// snapshots, and the children already render their solid stand-in, so the container
/// is a passthrough there.
public struct SuperGlassContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if SuperGlass.usesSolidFallback {
            content
        } else {
            GlassEffectContainer(spacing: spacing) { content }
        }
    }
}

/// Namespace for `SuperGlass`-internal shared state — keeps the solid-fallback
/// detection in one place for the modifier and the container.
enum SuperGlass {
    /// True when running inside an XCTest-hosted (or swift-testing) bundle, detected
    /// by XCTest being linked. The shipping app does not link XCTest, so this is
    /// `false` there and real glass renders.
    static var usesSolidFallback: Bool {
        NSClassFromString("XCTestCase") != nil
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
    /// Whether the glass itself reacts to touch (`.interactive()`). Independent
    /// of `assertsHitRegion`: a button can host inert glass (no liquid press)
    /// while still claiming the full-shape hit region.
    let glassInteractive: Bool
    /// Re-assert `shape` as the hit region. True for buttons (glass collapses it
    /// to the glyph); false for passive surfaces, or they'd swallow their inner
    /// controls' taps (e.g. the book/translation pill's two segments).
    let assertsHitRegion: Bool
    /// Overrides the theme's `glassTint` when non-nil (per-swatch colour, AI
    /// accent); `nil` falls back to the theme tint so existing callers are
    /// unchanged.
    let tint: Color?
    /// Liquid Glass morph identity, or `nil` for a static control.
    let morph: GlassMorphID?

    private var resolvedTint: Color { tint ?? theme.glassTint }

    @ViewBuilder
    func body(content: Content) -> some View {
        if assertsHitRegion {
            glassed(content).contentShape(shape)
        } else {
            glassed(content)
        }
    }

    @ViewBuilder
    private func glassed(_ content: Content) -> some View {
        if SuperGlass.usesSolidFallback {
            // Stand-in fill tracks the tint so tinted callers (highlight
            // swatches, accent AI tiles) stay visually distinct in snapshots;
            // untinted callers keep the original raised fill byte-for-byte. No
            // `glassEffectID` here: the morph it drives is invisible to
            // offscreen snapshots anyway.
            content
                .background(shape.fill(tint ?? theme.backgroundRaised))
                .overlay(shape.stroke(theme.borderFaint, lineWidth: 0.5))
        } else {
            morphed(
                content.glassEffect(
                    glassInteractive
                        ? Glass.regular.tint(resolvedTint).interactive()
                        : Glass.regular.tint(resolvedTint),
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
}
