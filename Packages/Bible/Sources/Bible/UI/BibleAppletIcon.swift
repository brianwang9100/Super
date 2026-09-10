import SwiftUI

/// Callers tint the 24-unit glyph through foregroundStyle.
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

struct BibleAppletIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + x / 24 * rect.width,
                y: rect.minY + y / 24 * rect.height
            )
        }

        // Book outline.
        p.move(to: at(6, 4))
        p.addLine(to: at(17, 4))
        p.addQuadCurve(to: at(19, 6), control: at(19, 4))
        p.addLine(to: at(19, 19))
        p.addQuadCurve(to: at(17, 21), control: at(19, 21))
        p.addLine(to: at(6, 21))
        p.addLine(to: at(5, 20))
        p.addLine(to: at(5, 5))
        p.addLine(to: at(6, 4))

        // Cover cross.
        p.move(to: at(12, 7))
        p.addLine(to: at(12, 15))
        p.move(to: at(9, 11))
        p.addLine(to: at(15, 11))
        return p
    }
}
