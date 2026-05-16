import SwiftUI

/// 24-unit canvas → caller-supplied size scale factor, so a stroke width
/// defined in canvas units maps cleanly onto point sizes.
private func scaled(_ pt: CGPoint, in rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + pt.x / 24 * rect.width,
            y: rect.minY + pt.y / 24 * rect.height)
}

private func move(_ p: inout Path, to pt: CGPoint, in rect: CGRect) {
    p.move(to: scaled(pt, in: rect))
}

private func line(_ p: inout Path, to pt: CGPoint, in rect: CGRect) {
    p.addLine(to: scaled(pt, in: rect))
}

/// Stroked-glyph wrapper. Defined locally so Todo doesn't import Chat for
/// one helper view.
struct StrokedGlyph<S: Shape>: View {
    let shape: S
    let size: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        shape
            .stroke(style: StrokeStyle(
                lineWidth: lineWidth,
                lineCap: .round,
                lineJoin: .round
            ))
            .frame(width: size, height: size)
    }
}

/// Checkmark-in-rounded-square — the Todo applet glyph.
struct TodoIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let outer = CGRect(
            x: rect.minX + 4 / 24 * rect.width,
            y: rect.minY + 4 / 24 * rect.height,
            width: 16 / 24 * rect.width,
            height: 16 / 24 * rect.height
        )
        p.addRoundedRect(in: outer, cornerSize: CGSize(
            width: 3 / 24 * rect.width,
            height: 3 / 24 * rect.height
        ))
        move(&p, to: CGPoint(x: 8, y: 12), in: rect)
        line(&p, to: CGPoint(x: 10.5, y: 14.5), in: rect)
        line(&p, to: CGPoint(x: 16, y: 9), in: rect)
        return p
    }
}

/// The Todo applet icon — used by `TodoApplet.iconView(size:)`.
public struct TodoIcon: View {
    let size: CGFloat

    public init(size: CGFloat) { self.size = size }

    public var body: some View {
        StrokedGlyph(shape: TodoIconShape(), size: size, lineWidth: 1.5)
    }
}
