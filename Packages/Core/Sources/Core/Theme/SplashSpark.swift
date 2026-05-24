import SwiftUI

/// 12-ray spark glyph used by `SplashView` and the brand wordmark lockup.
///
/// Coordinates are lifted from the handoff `spark.svg` (24×24 viewBox) and
/// normalized to `[0, 1]` so the shape scales cleanly to any frame. Each ray
/// is one stroked line with round caps; the alternating long/short pattern
/// gives the mark its sun/star reading without filling a path. Render with
/// `.stroke(..., lineWidth: ..., lineCap: .round)` — the path itself has no
/// fill.
public struct SplashSpark: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let x0 = rect.midX - size / 2
        let y0 = rect.midY - size / 2
        for ray in Self.rays {
            let p1 = CGPoint(x: x0 + ray.x1 * size, y: y0 + ray.y1 * size)
            let p2 = CGPoint(x: x0 + ray.x2 * size, y: y0 + ray.y2 * size)
            path.move(to: p1)
            path.addLine(to: p2)
        }
        return path
    }

    /// The 12 line endpoints, expressed as fractions of the glyph's bounding
    /// box (the SVG's 24-unit viewBox divided by 24). Order is clockwise
    /// starting from the top ray.
    private struct Ray { let x1, y1, x2, y2: CGFloat }
    private static let rays: [Ray] = [
        Ray(x1: 12.000 / 24, y1:  6.720 / 24, x2: 12.000 / 24, y2:  0.960 / 24),
        Ray(x1: 14.059 / 24, y1:  8.433 / 24, x2: 17.078 / 24, y2:  3.204 / 24),
        Ray(x1: 16.573 / 24, y1:  9.360 / 24, x2: 21.561 / 24, y2:  6.480 / 24),
        Ray(x1: 16.118 / 24, y1: 12.000 / 24, x2: 22.157 / 24, y2: 12.000 / 24),
        Ray(x1: 16.573 / 24, y1: 14.640 / 24, x2: 21.561 / 24, y2: 17.520 / 24),
        Ray(x1: 14.059 / 24, y1: 15.567 / 24, x2: 17.078 / 24, y2: 20.796 / 24),
        Ray(x1: 12.000 / 24, y1: 17.280 / 24, x2: 12.000 / 24, y2: 23.040 / 24),
        Ray(x1:  9.941 / 24, y1: 15.567 / 24, x2:  6.922 / 24, y2: 20.796 / 24),
        Ray(x1:  7.427 / 24, y1: 14.640 / 24, x2:  2.439 / 24, y2: 17.520 / 24),
        Ray(x1:  7.882 / 24, y1: 12.000 / 24, x2:  1.843 / 24, y2: 12.000 / 24),
        Ray(x1:  7.427 / 24, y1:  9.360 / 24, x2:  2.439 / 24, y2:  6.480 / 24),
        Ray(x1:  9.941 / 24, y1:  8.433 / 24, x2:  6.922 / 24, y2:  3.204 / 24),
    ]
}
