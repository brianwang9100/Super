import SwiftUI

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

struct RecipeIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Lid.
        move(&p, to: CGPoint(x: 6, y: 7), in: rect)
        line(&p, to: CGPoint(x: 6, y: 4), in: rect)
        line(&p, to: CGPoint(x: 18, y: 4), in: rect)
        line(&p, to: CGPoint(x: 18, y: 7), in: rect)
        // Pot body.
        move(&p, to: CGPoint(x: 5, y: 7), in: rect)
        line(&p, to: CGPoint(x: 19, y: 7), in: rect)
        line(&p, to: CGPoint(x: 17.6, y: 19.6), in: rect)
        line(&p, to: CGPoint(x: 15.6, y: 21), in: rect)
        line(&p, to: CGPoint(x: 8.4, y: 21), in: rect)
        line(&p, to: CGPoint(x: 6.4, y: 19.6), in: rect)
        line(&p, to: CGPoint(x: 5, y: 7), in: rect)
        move(&p, to: CGPoint(x: 9, y: 11), in: rect)
        line(&p, to: CGPoint(x: 9, y: 17), in: rect)
        move(&p, to: CGPoint(x: 12, y: 11), in: rect)
        line(&p, to: CGPoint(x: 12, y: 17), in: rect)
        move(&p, to: CGPoint(x: 15, y: 11), in: rect)
        line(&p, to: CGPoint(x: 15, y: 17), in: rect)
        return p
    }
}

struct FinanceIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        move(&p, to: CGPoint(x: 3, y: 17), in: rect)
        line(&p, to: CGPoint(x: 8, y: 12), in: rect)
        line(&p, to: CGPoint(x: 12, y: 16), in: rect)
        line(&p, to: CGPoint(x: 20, y: 8), in: rect)
        move(&p, to: CGPoint(x: 15, y: 8), in: rect)
        line(&p, to: CGPoint(x: 20, y: 8), in: rect)
        line(&p, to: CGPoint(x: 20, y: 13), in: rect)
        return p
    }
}

struct NewChatIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        move(&p, to: CGPoint(x: 12, y: 20), in: rect)
        line(&p, to: CGPoint(x: 21, y: 20), in: rect)
        // Tilted pencil body.
        move(&p, to: CGPoint(x: 16.5, y: 3.5), in: rect)
        p.addQuadCurve(
            to: scaled(CGPoint(x: 19.5, y: 6.5), in: rect),
            control: scaled(CGPoint(x: 19.0, y: 4.0), in: rect)
        )
        line(&p, to: CGPoint(x: 7, y: 19), in: rect)
        line(&p, to: CGPoint(x: 3, y: 20), in: rect)
        line(&p, to: CGPoint(x: 4, y: 16), in: rect)
        line(&p, to: CGPoint(x: 16.5, y: 3.5), in: rect)
        return p
    }
}

public struct RecipeIcon: View {
    let size: CGFloat
    public init(size: CGFloat = 20) { self.size = size }
    public var body: some View {
        StrokedGlyph(shape: RecipeIconShape(), size: size, lineWidth: 1.5)
    }
}

public struct FinanceIcon: View {
    let size: CGFloat
    public init(size: CGFloat = 20) { self.size = size }
    public var body: some View {
        StrokedGlyph(shape: FinanceIconShape(), size: size, lineWidth: 1.5)
    }
}

struct NewChatIcon: View {
    let size: CGFloat
    init(size: CGFloat = 20) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: NewChatIconShape(), size: size, lineWidth: 1.5)
    }
}
