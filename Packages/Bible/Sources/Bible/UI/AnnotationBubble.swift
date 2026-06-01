import Core
import SwiftUI

/// The pill speech-bubble glyph that marks a book / chapter / verse as
/// annotated.
///
/// Three states drive the silhouette:
///
/// - `.empty` — outlined; the target has zero annotation rows and tapping
///   will fire `bible.annotate` to generate one.
/// - `.generating` — outlined with three static ellipsis dots inside;
///   shown while a generation request is in flight.
/// - `.filled` — solid-accent fill; the target has ≥1 annotation row and
///   tapping opens `AnnotationSheet`.
///
/// The shape is a hand-drawn `Path` rather than an SF Symbol because SF
/// Symbols' bubble variants don't share the JSX design's pill proportions
/// or bottom-left tail angle. Stroke width is `1.6` of a 24-unit viewbox,
/// scaled to the caller's requested `size`; this matches the design
/// canvas's 24×24 grid exactly.
struct AnnotationBubble: View {
    @Environment(\.superTheme) private var theme

    /// Named `BubbleState` rather than `State` to avoid shadowing
    /// `SwiftUI.State` within this struct's scope — the same naming
    /// rationale `AnnotationBlock.Content` follows to avoid clashing
    /// with `View.body`.
    enum BubbleState: Sendable, Equatable {
        case empty
        case generating
        case filled
    }

    let state: BubbleState
    let size: CGFloat

    init(state: BubbleState, size: CGFloat = 16) {
        self.state = state
        self.size = size
    }

    /// Derive the bubble state for a target from its annotation-row
    /// presence and in-flight generation status. `filled` wins over
    /// `generating`: once rows exist the user should be able to view them
    /// even if a regenerate is mid-flight. A pure factory so both the
    /// chapter-title and book-picker bubbles share one rule and a unit
    /// test can cover it without a SwiftUI host.
    static func state(hasAnnotation: Bool, isGenerating: Bool) -> BubbleState {
        if hasAnnotation { return .filled }
        if isGenerating { return .generating }
        return .empty
    }

    /// Horizontal ink bounds in 24-unit design coordinates, padded by the
    /// half stroke width (`1.6 / 2`) so round joins aren't clipped. The frame
    /// hugs this range rather than the full 24-unit square, so the glyph
    /// carries no empty side-bearing and adjacent glyphs gap by exactly the
    /// layout spacing. The range is centred on x=12, so single / centred
    /// placements render identically to the old square frame.
    private static let inkMinX: CGFloat = 2.2   // body left (3) − half stroke
    private static let inkMaxX: CGFloat = 21.8  // body right (21) + half stroke

    var body: some View {
        let scale = size / 24.0
        let inkWidth = (Self.inkMaxX - Self.inkMinX) * scale
        return Canvas { context, _ in
            // Vertical mapping stays on the full 24-unit grid (frame height is
            // `size`); shift left so the ink range sits flush in the trimmed
            // width.
            context.translateBy(x: -Self.inkMinX * scale, y: 0)
            let path = bubblePath(scale: scale)
            switch state {
            case .filled:
                context.fill(path, with: .color(theme.accent))
                // Stroke in the fill colour too: a stroke straddles the path
                // (extends ~half its width beyond the edge), so the outlined
                // states read slightly larger than a fill-only shape. Matching
                // the stroke here keeps filled and empty bubbles the same size.
                context.stroke(
                    path,
                    with: .color(theme.accent),
                    style: StrokeStyle(lineWidth: 1.6 * scale, lineCap: .round, lineJoin: .round)
                )
            case .empty, .generating:
                context.stroke(
                    path,
                    with: .color(theme.inkFaint),
                    style: StrokeStyle(lineWidth: 1.6 * scale, lineCap: .round, lineJoin: .round)
                )
            }
            if state == .generating {
                for x in [8.5, 12.0, 15.5] {
                    let dot = Path(ellipseIn: CGRect(
                        x: (x - 1.2) * scale,
                        y: (10.0 - 1.2) * scale,
                        width: 2.4 * scale,
                        height: 2.4 * scale
                    ))
                    context.fill(dot, with: .color(theme.inkFaint))
                }
            }
        }
        .frame(width: inkWidth, height: size)
        .accessibilityHidden(true)
    }

    /// The 24×24 path from `atoms.jsx`:
    /// `M5 4 h14 a2 2 0 0 1 2 2 v8 a2 2 0 0 1 -2 2 h-9.2 l-3.8 3 v-3 H5
    /// a2 2 0 0 1 -2 -2 V6 a2 2 0 0 1 2 -2 z`, scaled into the canvas.
    private func bubblePath(scale: CGFloat) -> Path {
        var path = Path()
        // Rounded body: top-left (5,4) → top-right (19,4), 2-unit corner.
        path.move(to: CGPoint(x: 5 * scale, y: 4 * scale))
        path.addLine(to: CGPoint(x: 19 * scale, y: 4 * scale))
        path.addArc(
            tangent1End: CGPoint(x: 21 * scale, y: 4 * scale),
            tangent2End: CGPoint(x: 21 * scale, y: 6 * scale),
            radius: 2 * scale
        )
        path.addLine(to: CGPoint(x: 21 * scale, y: 14 * scale))
        path.addArc(
            tangent1End: CGPoint(x: 21 * scale, y: 16 * scale),
            tangent2End: CGPoint(x: 19 * scale, y: 16 * scale),
            radius: 2 * scale
        )
        // Tail: bottom edge breaks at x=9.8, drops to (6, 19), returns to x=6.
        path.addLine(to: CGPoint(x: 9.8 * scale, y: 16 * scale))
        path.addLine(to: CGPoint(x: 6 * scale, y: 19 * scale))
        path.addLine(to: CGPoint(x: 6 * scale, y: 16 * scale))
        path.addLine(to: CGPoint(x: 5 * scale, y: 16 * scale))
        path.addArc(
            tangent1End: CGPoint(x: 3 * scale, y: 16 * scale),
            tangent2End: CGPoint(x: 3 * scale, y: 14 * scale),
            radius: 2 * scale
        )
        path.addLine(to: CGPoint(x: 3 * scale, y: 6 * scale))
        path.addArc(
            tangent1End: CGPoint(x: 3 * scale, y: 4 * scale),
            tangent2End: CGPoint(x: 5 * scale, y: 4 * scale),
            radius: 2 * scale
        )
        path.closeSubpath()
        return path
    }
}
