import Core
import SwiftUI

// Custom 24-unit geometry preserves the design's pill proportions and tail angle.
struct AnnotationBubble: View {
    @Environment(\.superTheme) private var theme

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

    /// Existing content wins over generation so the user can open it while regeneration runs.
    static func state(hasAnnotation: Bool, isGenerating: Bool) -> BubbleState {
        if hasAnnotation { return .filled }
        if isGenerating { return .generating }
        return .empty
    }

    // Include half the stroke in horizontal ink bounds to avoid clipping and empty side-bearing.
    private static let inkMinX: CGFloat = 2.2   // body left (3) − half stroke
    private static let inkMaxX: CGFloat = 21.8  // body right (21) + half stroke

    var body: some View {
        let scale = size / 24.0
        let inkWidth = (Self.inkMaxX - Self.inkMinX) * scale
        return Canvas { context, _ in
            // Keep full-grid height while aligning the trimmed ink width to the frame.
            context.translateBy(x: -Self.inkMinX * scale, y: 0)
            let path = bubblePath(scale: scale)
            switch state {
            case .filled:
                context.fill(path, with: .color(theme.accent))
                // Match the outline stroke so filled and empty states have identical visible bounds.
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

    // Geometry follows the 24-unit design in atoms.jsx.
    private func bubblePath(scale: CGFloat) -> Path {
        var path = Path()
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
