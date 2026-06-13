import SwiftUI

/// Stroked ribbon-bookmark glyph for the Bookmarks mini-applet's sidebar
/// rail icon. Shares the ribbon silhouette of `BookmarkGlyph` (the reader's
/// chapter-title mark) so the rail row and the in-reader affordance read as
/// the same object, but renders as a clean outline — the rail convention the
/// `BibleAppletIcon` book glyph follows.
///
/// Strokes `Color.primary` by default; callers tint via `.foregroundStyle`.
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

/// Path shape extracted so the icon can be reused as a mask or recoloured
/// per theme without re-creating the view hierarchy — mirrors
/// `BibleAppletIconShape`.
struct BookmarksAppletIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        // 24-unit canvas → caller-supplied rect scale. The ribbon matches
        // `BookmarkGlyph.ribbonPath`'s grid: rounded top corners (radius 2),
        // straight sides, a bottom notch rising to the centre.
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
