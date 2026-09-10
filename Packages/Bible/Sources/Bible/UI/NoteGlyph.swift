import Core
import SwiftUI

// Custom 24-unit geometry preserves the design's page proportions and fold angle.
struct NoteGlyph: View {
    @Environment(\.superTheme) private var theme

    enum GlyphState: Sendable, Equatable {
        case filled
        case outline
    }

    let state: GlyphState
    let size: CGFloat

    init(state: GlyphState = .filled, size: CGFloat = 16) {
        self.state = state
        self.size = size
    }

    // Include half the stroke in ink bounds to prevent clipping without empty side-bearing.
    private static let inkMinX: CGFloat = 4.2   // page left (5) − half stroke
    private static let inkMaxX: CGFloat = 19.8  // page right (19) + half stroke

    var body: some View {
        let scale = size / 24.0
        let inkWidth = (Self.inkMaxX - Self.inkMinX) * scale
        return Canvas { context, _ in
            // Keep full-grid height while aligning the trimmed ink width to the frame.
            context.translateBy(x: -Self.inkMinX * scale, y: 0)
            let page = pagePath(scale: scale)
            let detail = detailPath(scale: scale)
            switch state {
            case .filled:
                context.fill(page, with: .color(theme.accent))
                // Stroke the fill too so filled and outline states have equal visible bounds.
                context.stroke(page, with: .color(theme.accent), style: stroke(scale: scale))
                context.stroke(
                    detail,
                    with: .color(theme.accentInk.opacity(0.85)),
                    style: stroke(scale: scale)
                )
            case .outline:
                context.stroke(page, with: .color(theme.inkFaint), style: stroke(scale: scale))
                context.stroke(detail, with: .color(theme.inkFaint), style: stroke(scale: scale))
            }
        }
        .frame(width: inkWidth, height: size)
        .accessibilityHidden(true)
    }

    private func stroke(scale: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: 1.6 * scale, lineCap: .round, lineJoin: .round)
    }

    // Page geometry follows notes/atoms.jsx.
    private func pagePath(scale: CGFloat) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }
        var path = Path()
        path.move(to: p(14, 3.4))
        path.addLine(to: p(7, 3.4))
        path.addArc(tangent1End: p(5, 3.4), tangent2End: p(5, 5.4), radius: 2 * scale)
        path.addLine(to: p(5, 18.6))
        path.addArc(tangent1End: p(5, 20.6), tangent2End: p(7, 20.6), radius: 2 * scale)
        path.addLine(to: p(17, 20.6))
        path.addArc(tangent1End: p(19, 20.6), tangent2End: p(19, 18.6), radius: 2 * scale)
        path.addLine(to: p(19, 8.4))
        path.closeSubpath()                                           // diagonal fold cut
        return path
    }

    private func detailPath(scale: CGFloat) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }
        var path = Path()
        // Fold crease.
        path.move(to: p(14, 3.4))
        path.addLine(to: p(14, 6.8))
        path.addArc(tangent1End: p(14, 8.4), tangent2End: p(15.6, 8.4), radius: 1.6 * scale)
        path.addLine(to: p(19, 8.4))
        // Ruled lines.
        path.move(to: p(8.6, 13))
        path.addLine(to: p(15.4, 13))
        path.move(to: p(8.6, 16.2))
        path.addLine(to: p(15.4, 16.2))
        return path
    }
}
