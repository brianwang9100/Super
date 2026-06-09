import SwiftUI

/// Sixteen-point Star of Bethlehem — SuperBible's brand mark, used as the
/// chat empty-state hero icon.
///
/// The path geometry mirrors `starPath()` in
/// `Scripts/generate_superbible_brand_assets.swift` (the generator that
/// renders the app icon, splash, and launch screen): 16 points, radii
/// alternating long / short / waist in the proportion `44 : 22 : 8`,
/// starting at the top. That script is a standalone CLI tool and can't
/// import Chat, so the geometry is shared by convention — keep the two in
/// sync. The long points touch the frame edges, so `size` is the star's
/// drawn diameter. Fills with the current foreground, so a caller tints it
/// with `.foregroundStyle(theme.accent)`.
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

/// The filled 16-point star path, scaled so its long points reach the
/// edges of `rect`. Radii keep the generator script's `44 : 22 : 8`
/// proportion (long on every fourth point, short on the even points
/// between, waist on the odd points).
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
