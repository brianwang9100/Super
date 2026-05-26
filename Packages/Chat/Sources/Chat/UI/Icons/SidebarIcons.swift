import SwiftUI

/// Stroked Scalable Vector Graphics (SVG)-style applet glyphs used by
/// `SidebarDrawer`.
///
/// Each icon mirrors the shape from
/// `.design-tmp/chat/project/src/icons.jsx`. SwiftUI's `Path` is fed the
/// same coordinates as the original 24×24 viewBox; the wrapper view scales
/// the path to the requested point size so the stroke width stays
/// visually consistent.
///
/// The icons stroke `Color.primary` by default. Callers tint by setting
/// `.foregroundStyle(...)` on the parent.
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

/// 24-unit canvas → caller-supplied size scale factor. Used by every icon
/// shape so the stroke widths defined in pixels map cleanly to point sizes.
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

// MARK: - Applet glyphs (mirrors icons.jsx)

/// Pot-with-handles glyph — the Recipes applet.
struct RecipeIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Lid
        move(&p, to: CGPoint(x: 6, y: 7), in: rect)
        line(&p, to: CGPoint(x: 6, y: 4), in: rect)
        line(&p, to: CGPoint(x: 18, y: 4), in: rect)
        line(&p, to: CGPoint(x: 18, y: 7), in: rect)
        // Pot body — a stylized U with a slight taper.
        move(&p, to: CGPoint(x: 5, y: 7), in: rect)
        line(&p, to: CGPoint(x: 19, y: 7), in: rect)
        line(&p, to: CGPoint(x: 17.6, y: 19.6), in: rect)
        line(&p, to: CGPoint(x: 15.6, y: 21), in: rect)
        line(&p, to: CGPoint(x: 8.4, y: 21), in: rect)
        line(&p, to: CGPoint(x: 6.4, y: 19.6), in: rect)
        line(&p, to: CGPoint(x: 5, y: 7), in: rect)
        // Slats
        move(&p, to: CGPoint(x: 9, y: 11), in: rect)
        line(&p, to: CGPoint(x: 9, y: 17), in: rect)
        move(&p, to: CGPoint(x: 12, y: 11), in: rect)
        line(&p, to: CGPoint(x: 12, y: 17), in: rect)
        move(&p, to: CGPoint(x: 15, y: 11), in: rect)
        line(&p, to: CGPoint(x: 15, y: 17), in: rect)
        return p
    }
}

/// Trending-up sparkline glyph — the Finance applet.
struct FinanceIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        move(&p, to: CGPoint(x: 3, y: 17), in: rect)
        line(&p, to: CGPoint(x: 8, y: 12), in: rect)
        line(&p, to: CGPoint(x: 12, y: 16), in: rect)
        line(&p, to: CGPoint(x: 20, y: 8), in: rect)
        // Arrowhead
        move(&p, to: CGPoint(x: 15, y: 8), in: rect)
        line(&p, to: CGPoint(x: 20, y: 8), in: rect)
        line(&p, to: CGPoint(x: 20, y: 13), in: rect)
        return p
    }
}

/// Pencil-on-line glyph — the New Chat CTA.
struct NewChatIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Underline
        move(&p, to: CGPoint(x: 12, y: 20), in: rect)
        line(&p, to: CGPoint(x: 21, y: 20), in: rect)
        // Pencil shape (simplified — a tilted rect with a tip)
        move(&p, to: CGPoint(x: 16.5, y: 3.5), in: rect)
        // top-right grip
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

// MARK: - Public icon views

/// Recipes applet glyph.
public struct RecipeIcon: View {
    let size: CGFloat
    public init(size: CGFloat = 20) { self.size = size }
    public var body: some View {
        StrokedGlyph(shape: RecipeIconShape(), size: size, lineWidth: 1.5)
    }
}

/// Finance applet glyph.
public struct FinanceIcon: View {
    let size: CGFloat
    public init(size: CGFloat = 20) { self.size = size }
    public var body: some View {
        StrokedGlyph(shape: FinanceIconShape(), size: size, lineWidth: 1.5)
    }
}

/// New-Chat (pencil) glyph. Internal-only (used inside the sidebar drawer).
struct NewChatIcon: View {
    let size: CGFloat
    init(size: CGFloat = 20) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: NewChatIconShape(), size: size, lineWidth: 1.5)
    }
}

