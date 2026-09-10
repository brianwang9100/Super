import SwiftUI

/// Matches BookmarkGlyph's silhouette; callers tint through foregroundStyle.
public struct BookmarksAppletIcon: View {
    public let size: CGFloat

    public init(size: CGFloat = 20) {
        self.size = size
    }

    public var body: some View {
        BookmarksAppletIconShape()
            .stroke(style: StrokeStyle(
                lineWidth: 1.5,
                lineCap: .round,
                lineJoin: .round
            ))
            .frame(width: size, height: size)
    }
}

struct BookmarksAppletIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + x / 24 * rect.width,
                y: rect.minY + y / 24 * rect.height
            )
        }
        func r(_ value: CGFloat) -> CGFloat { value / 24 * rect.width }

        var p = Path()
        p.move(to: at(6, 20.8))
        p.addLine(to: at(6, 5.4))
        p.addArc(tangent1End: at(6, 3.4), tangent2End: at(8, 3.4), radius: r(2))
        p.addLine(to: at(16, 3.4))
        p.addArc(tangent1End: at(18, 3.4), tangent2End: at(18, 5.4), radius: r(2))
        p.addLine(to: at(18, 20.8))
        p.addLine(to: at(12, 16.2))
        p.closeSubpath()
        return p
    }
}
