import Core
import SwiftUI

// Custom 24-unit geometry matches annotation/note glyph proportions.
struct BookmarkGlyph: View {
    @Environment(\.superTheme) private var theme

    enum GlyphState: Sendable, Equatable {
        case filled(BibleBookmarkColor)
        case unassigned(BibleBookmarkColor)
        case outline
    }

    let state: GlyphState
    let size: CGFloat

    init(state: GlyphState = .outline, size: CGFloat = 16) {
        self.state = state
        self.size = size
    }

    // Include half the stroke in ink bounds to prevent clipping without empty side-bearing.
    private static let inkMinX: CGFloat = 5.2   // ribbon left (6) − half stroke
    private static let inkMaxX: CGFloat = 18.8  // ribbon right (18) + half stroke

    var body: some View {
        let scale = size / 24.0
        let inkWidth = (Self.inkMaxX - Self.inkMinX) * scale
        return Canvas { context, _ in
            context.translateBy(x: -Self.inkMinX * scale, y: 0)
            let ribbon = ribbonPath(scale: scale)
            switch state {
            case .filled(let color):
                let tint = color.tint(forDarkTheme: theme.isDark).color
                context.fill(ribbon, with: .color(tint))
                // Stroke the fill too so filled and outline states have equal visible bounds.
                context.stroke(ribbon, with: .color(tint), style: stroke(scale: scale))
            case .unassigned(let color):
                let fill = color.softTint(forDarkTheme: theme.isDark).color
                let edge = color.tint(forDarkTheme: theme.isDark).color
                context.fill(ribbon, with: .color(fill))
                context.stroke(ribbon, with: .color(edge), style: stroke(scale: scale))
            case .outline:
                context.stroke(ribbon, with: .color(theme.inkFaint), style: stroke(scale: scale))
            }
        }
        .frame(width: inkWidth, height: size)
        .accessibilityHidden(true)
    }

    private func stroke(scale: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: 1.6 * scale, lineCap: .round, lineJoin: .round)
    }

    private func ribbonPath(scale: CGFloat) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }
        var path = Path()
        path.move(to: p(6, 20.8))
        path.addLine(to: p(6, 5.4))
        path.addArc(tangent1End: p(6, 3.4), tangent2End: p(8, 3.4), radius: 2 * scale)
        path.addLine(to: p(16, 3.4))
        path.addArc(tangent1End: p(18, 3.4), tangent2End: p(18, 5.4), radius: 2 * scale)
        path.addLine(to: p(18, 20.8))
        path.addLine(to: p(12, 16.2))
        path.closeSubpath()
        return path
    }
}
