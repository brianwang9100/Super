import SwiftUI

struct ChatsIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let unitX = rect.width / 24
        let unitY = rect.height / 24
        let strokes: [(start: CGPoint, end: CGPoint)] = [
            (CGPoint(x: 4, y: 7),  CGPoint(x: 20, y: 7)),
            (CGPoint(x: 4, y: 12), CGPoint(x: 15, y: 12)),
            (CGPoint(x: 4, y: 17), CGPoint(x: 20, y: 17)),
        ]
        for stroke in strokes {
            p.move(to: CGPoint(
                x: rect.minX + stroke.start.x * unitX,
                y: rect.minY + stroke.start.y * unitY
            ))
            p.addLine(to: CGPoint(
                x: rect.minX + stroke.end.x * unitX,
                y: rect.minY + stroke.end.y * unitY
            ))
        }
        return p
    }
}

public struct ChatsIcon: View {
    let size: CGFloat
    public init(size: CGFloat = 20) { self.size = size }
    public var body: some View {
        StrokedGlyph(shape: ChatsIconShape(), size: size, lineWidth: 1.8)
    }
}
