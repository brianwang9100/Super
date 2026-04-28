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

/// Checkmark-in-rounded-square — the Todo applet glyph.
struct TodoIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // RoundedRect outer
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
        // Check
        move(&p, to: CGPoint(x: 8, y: 12), in: rect)
        line(&p, to: CGPoint(x: 10.5, y: 14.5), in: rect)
        line(&p, to: CGPoint(x: 16, y: 9), in: rect)
        return p
    }
}

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

/// Book glyph with cross — the Bible applet.
struct BibleIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Book outline (rounded right edge)
        move(&p, to: CGPoint(x: 6, y: 4), in: rect)
        line(&p, to: CGPoint(x: 17, y: 4), in: rect)
        // Use a quadCurve for the rounded top-right
        p.addQuadCurve(
            to: scaled(CGPoint(x: 19, y: 6), in: rect),
            control: scaled(CGPoint(x: 19, y: 4), in: rect)
        )
        line(&p, to: CGPoint(x: 19, y: 19), in: rect)
        p.addQuadCurve(
            to: scaled(CGPoint(x: 17, y: 21), in: rect),
            control: scaled(CGPoint(x: 19, y: 21), in: rect)
        )
        line(&p, to: CGPoint(x: 6, y: 21), in: rect)
        line(&p, to: CGPoint(x: 5, y: 20), in: rect)
        line(&p, to: CGPoint(x: 5, y: 5), in: rect)
        line(&p, to: CGPoint(x: 6, y: 4), in: rect)
        // Cross
        move(&p, to: CGPoint(x: 12, y: 7), in: rect)
        line(&p, to: CGPoint(x: 12, y: 15), in: rect)
        move(&p, to: CGPoint(x: 9, y: 11), in: rect)
        line(&p, to: CGPoint(x: 15, y: 11), in: rect)
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

/// Six-tooth gear with center hole — the Settings glyph.
///
/// Approximates the SVG settings cog from `icons.jsx` while staying
/// resolution-independent. The detailed teeth lobes are simplified into a
/// stroked outer ring; the center punch-out matches the design.
struct SettingsIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let cx = rect.midX
        let cy = rect.midY
        let unit = rect.width / 24
        let outer: CGFloat = 9 * unit
        let inner: CGFloat = 6.5 * unit
        let toothHalf: Double = .pi / 12
        let teeth = 8

        for i in 0..<teeth {
            let a = Double(i) * (.pi * 2 / Double(teeth))
            let a0 = a - toothHalf
            let a1 = a + toothHalf
            let a2 = a + .pi / Double(teeth) - toothHalf
            let a3 = a + .pi / Double(teeth) + toothHalf

            let p0 = CGPoint(x: cx + cos(a0) * outer, y: cy + sin(a0) * outer)
            let p1 = CGPoint(x: cx + cos(a1) * outer, y: cy + sin(a1) * outer)
            let p2 = CGPoint(x: cx + cos(a2) * inner, y: cy + sin(a2) * inner)
            let p3 = CGPoint(x: cx + cos(a3) * inner, y: cy + sin(a3) * inner)

            if i == 0 { p.move(to: p0) } else { p.addLine(to: p0) }
            p.addLine(to: p1)
            p.addLine(to: p2)
            p.addLine(to: p3)
        }
        p.closeSubpath()

        // Center circle.
        let centerSize: CGFloat = 6 * unit
        p.addEllipse(in: CGRect(
            x: cx - centerSize / 2,
            y: cy - centerSize / 2,
            width: centerSize,
            height: centerSize
        ))
        return p
    }
}

// MARK: - Public icon views

/// Todo applet glyph.
struct TodoIcon: View {
    let size: CGFloat
    init(size: CGFloat = 20) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: TodoIconShape(), size: size, lineWidth: 1.5)
    }
}

/// Recipes applet glyph.
struct RecipeIcon: View {
    let size: CGFloat
    init(size: CGFloat = 20) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: RecipeIconShape(), size: size, lineWidth: 1.5)
    }
}

/// Bible applet glyph.
struct BibleIcon: View {
    let size: CGFloat
    init(size: CGFloat = 20) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: BibleIconShape(), size: size, lineWidth: 1.5)
    }
}

/// Finance applet glyph.
struct FinanceIcon: View {
    let size: CGFloat
    init(size: CGFloat = 20) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: FinanceIconShape(), size: size, lineWidth: 1.5)
    }
}

/// New-Chat (pencil) glyph.
struct NewChatIcon: View {
    let size: CGFloat
    init(size: CGFloat = 20) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: NewChatIconShape(), size: size, lineWidth: 1.5)
    }
}

/// Settings (gear) glyph.
struct SettingsIcon: View {
    let size: CGFloat
    init(size: CGFloat = 20) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: SettingsIconShape(), size: size, lineWidth: 1.5)
    }
}
