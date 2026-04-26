import SwiftUI

/// Twelve-spoke radial spark used as the empty-state hero icon.
///
/// Mirrors `IconSpark` from `.design-tmp/chat/project/src/icons.jsx`: 12
/// spokes around the center, alternating short/long, drawn at a fixed
/// size with `var(--accent)` stroke.
public struct SparkIcon: View {
    public let size: CGFloat

    public init(size: CGFloat = 36) {
        self.size = size
    }

    public var body: some View {
        Canvas { ctx, geo in
            let center = CGPoint(x: geo.width / 2, y: geo.height / 2)
            let unit = geo.width / 24.0
            for i in 0..<12 {
                let angle = Double(i) * .pi * 2 / 12
                let isMajor = i % 2 == 0
                let r1 = (isMajor ? 5.0 : 3.5) * unit
                let r2 = (isMajor ? 11.0 : 9.0) * unit
                var path = Path()
                path.move(to: CGPoint(
                    x: center.x + cos(angle) * r1,
                    y: center.y + sin(angle) * r1
                ))
                path.addLine(to: CGPoint(
                    x: center.x + cos(angle) * r2,
                    y: center.y + sin(angle) * r2
                ))
                ctx.stroke(
                    path,
                    with: .color(.primary),
                    style: StrokeStyle(lineWidth: 1.3 * unit, lineCap: .round)
                )
            }
        }
        .frame(width: size, height: size)
    }
}
