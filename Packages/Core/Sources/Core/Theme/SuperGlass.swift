import Foundation
import SwiftUI

/// Matching IDs in one namespace/GlassEffectContainer morph across animated hierarchy changes.
public struct GlassMorphID {
    let id: String
    let namespace: Namespace.ID

    public init(_ id: String, in namespace: Namespace.ID) {
        self.id = id
        self.namespace = namespace
    }
}

public extension View {
    /// Theme-tinted glass restores the full shape's hit region. Remove old fill/border/shadow chrome.
    /// Nil tint uses the theme. Dense clusters can glow-flicker on release; use
    /// interactive: false with SuperPressButtonStyle for those controls.
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

    /// Accent-tinted CTA glass; pair the glyph with theme.accentInk for contrast.
    func superGlassCTAButton(in shape: some Shape = Circle()) -> some View {
        modifier(SuperGlassCTAModifier(shape: shape))
    }

    /// Passive regular glass keeps text legible and leaves taps to inner controls.
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

private struct SuperGlassCTAModifier<S: Shape>: ViewModifier {
    @Environment(\.superTheme) private var theme

    let shape: S

    func body(content: Content) -> some View {
        content.superGlassButton(in: shape, tint: theme.accent)
    }
}

/// Pair with noninteractive glass to avoid dense-cluster glow flicker. The button
/// label must be the glass surface so press scaling stays centered.
public struct SuperPressButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PressScale(configuration: configuration)
    }

    private struct PressScale: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let configuration: ButtonStyleConfiguration

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .animation(
                    reduceMotion ? SuperMotion.reducedMotion : SuperMotion.press,
                    value: configuration.isPressed
                )
        }
    }
}

/// Fires at touch-down. Nil pattern is silent; scale adds SuperPressButtonStyle
/// feedback for noninteractive glass. Leave scale off when glass supplies its own press.
public struct GlassHapticButtonStyle: ButtonStyle {
    private let pattern: HapticPattern?
    private let scale: Bool

    public init(_ pattern: HapticPattern? = .selection, scale: Bool = false) {
        self.pattern = pattern
        self.scale = scale
    }

    public func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, pattern: pattern, scale: scale)
    }

    private struct PressBody: View {
        @Environment(\.hapticsEngine) private var hapticsEngine
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let configuration: ButtonStyleConfiguration
        let pattern: HapticPattern?
        let scale: Bool

        var body: some View {
            // Even identity scale/animation layers change compositing and subpixel antialiasing.
            // Keep scale: false a pure passthrough to preserve unscaled rendering.
            if scale {
                configuration.label
                    .scaleEffect(configuration.isPressed ? 0.9 : 1)
                    .animation(
                        reduceMotion ? SuperMotion.reducedMotion : SuperMotion.press,
                        value: configuration.isPressed
                    )
                    .onChange(of: configuration.isPressed, fire)
            } else {
                configuration.label
                    .onChange(of: configuration.isPressed, fire)
            }
        }

        @MainActor
        private func fire(_ wasPressed: Bool, _ isPressed: Bool) {
            guard isPressed, let pattern else { return }
            hapticsEngine.play(pattern)
        }
    }
}

/// Glass cannot sample neighboring glass, so independent tight cells create overlapping
/// shadows. Share one sampling region; keep spacing below the cell gap (0 disables
/// merging). Test hosts pass through because children already use solid stand-ins.
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

enum SuperGlass {
    static var usesSolidFallback: Bool {
        NSClassFromString("XCTestCase") != nil
    }
}

// Offscreen Liquid Glass captures transparent (swift-snapshot-testing discussion #1031);
// even onscreen hosts can record tint as gray (#1019). Test hosts use a solid
// fallback for layout coverage; real material appearance requires device verification.
private struct SuperGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.superTheme) private var theme

    let shape: S
    let glassInteractive: Bool
    // Glass shrinks hit regions to glyphs. Restore buttons' full shape, but let passive
    // surfaces preserve their inner controls' taps.
    let assertsHitRegion: Bool
    let tint: Color?
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
            // Preserve tint distinctions in snapshots; offscreen captures cannot show morphing.
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

    @ViewBuilder
    private func morphed(_ content: some View) -> some View {
        if let morph {
            content.glassEffectID(morph.id, in: morph.namespace)
        } else {
            content
        }
    }
}
