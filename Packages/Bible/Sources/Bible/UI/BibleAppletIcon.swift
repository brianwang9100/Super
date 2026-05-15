import SwiftUI

/// Stroked book-with-cross glyph rendered in the sidebar applet rail and the
/// M0 placeholder badge. The coordinates mirror the 24×24 viewBox used in
/// `/tmp/super-design/super/project/bible/sheets.jsx` (`iconPath: 'M6 4h11a2
/// 2 0 0 1 2 2v13a2 2 0 0 1-2 2H6a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1zM12 7v8M9 11
/// h6'`).
///
/// Strokes `Color.primary` by default; callers tint via `.foregroundStyle`.
public struct BibleAppletIcon: View {
    public let size: CGFloat

    public init(size: CGFloat = 20) {
        self.size = size
    }

    public var body: some View {
        BibleAppletIconShape()
            .stroke(style: StrokeStyle(
                lineWidth: 1.5,
                lineCap: .round,
                lineJoin: .round
            ))
            .frame(width: size, height: size)
    }
}

/// Path shape extracted so the icon can be reused as a mask, recoloured per
/// theme, or composed inside other surfaces (e.g. the chat-attach toast)
/// without re-creating the view hierarchy.
struct BibleAppletIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // 24-unit canvas → caller-supplied rect scale, mirroring the
        // helper pattern used in Chat's `SidebarIcons.swift`.
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + x / 24 * rect.width,
                y: rect.minY + y / 24 * rect.height
            )
        }

        // Book outline with a rounded top-right and bottom-right.
        p.move(to: at(6, 4))
        p.addLine(to: at(17, 4))
        p.addQuadCurve(to: at(19, 6), control: at(19, 4))
        p.addLine(to: at(19, 19))
        p.addQuadCurve(to: at(17, 21), control: at(19, 21))
        p.addLine(to: at(6, 21))
        p.addLine(to: at(5, 20))
        p.addLine(to: at(5, 5))
        p.addLine(to: at(6, 4))

        // Cross on the cover.
        p.move(to: at(12, 7))
        p.addLine(to: at(12, 15))
        p.move(to: at(9, 11))
        p.addLine(to: at(15, 11))
        return p
    }
}
