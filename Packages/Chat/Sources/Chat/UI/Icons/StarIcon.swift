import SwiftUI

/// Keep geometry in sync with starPath() in Scripts/generate_superbible_brand_assets.swift;
/// the standalone generator cannot import Chat. Size is the long-point diameter.
public struct StarIcon: View {
    public let size: CGFloat

    public init(size: CGFloat = 40) {
        self.size = size
    }

    public var body: some View {
        StarOfBethlehemShape()
            .fill(.foreground)
            .frame(width: size, height: size)
    }
}

private struct StarOfBethlehemShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let scale = min(rect.width, rect.height) / 2 / 44
        var path = Path()
        for i in 0..<16 {
            let angle = Double(i) * .pi * 2 / 16 - .pi / 2
            let radius = ((i % 4 == 0) ? 44.0 : (i % 2 == 0 ? 22.0 : 8.0)) * scale
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
