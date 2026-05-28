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

    enum State: Sendable, Equatable {
        case empty
        case generating
        case filled
    }

    let state: State
    let size: CGFloat

    init(state: State, size: CGFloat = 16) {
        self.state = state
        self.size = size
    }

    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 24.0
            let path = bubblePath(scale: scale)
            switch state {
            case .filled:
                context.fill(path, with: .color(theme.accent))
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
        .frame(width: size, height: size)
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
