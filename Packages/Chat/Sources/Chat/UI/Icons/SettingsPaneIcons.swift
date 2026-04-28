import SwiftUI

/// Stroked Scalable Vector Graphics (SVG)-style glyphs used by the Settings
/// sheet — chrome icons (close, back, chevron, plus, check) and the eight
/// row-leading icons inside the root pane.
///
/// Each `Shape` mirrors the path data from `settings.jsx`'s `iconFor` block
/// (or `icons.jsx` for the chrome glyphs), expressed in a 24-unit viewBox
/// scaled into the requested point size at draw time. Stroke width tracks
/// the source SVG's `strokeWidth`. The `StrokedGlyph` wrapper from
/// `SidebarIcons.swift` is reused so the visual treatment stays consistent.

private func sscale(_ pt: CGPoint, in rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + pt.x / 24 * rect.width,
            y: rect.minY + pt.y / 24 * rect.height)
}

private func smove(_ p: inout Path, _ pt: CGPoint, in rect: CGRect) {
    p.move(to: sscale(pt, in: rect))
}

private func sline(_ p: inout Path, _ pt: CGPoint, in rect: CGRect) {
    p.addLine(to: sscale(pt, in: rect))
}

// MARK: - Chrome glyphs (close, back, chevron, plus, check)

/// `IconClose` — diagonal X used by the sheet's root-pane close button.
struct CloseGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        smove(&p, CGPoint(x: 6, y: 6), in: rect)
        sline(&p, CGPoint(x: 18, y: 18), in: rect)
        smove(&p, CGPoint(x: 18, y: 6), in: rect)
        sline(&p, CGPoint(x: 6, y: 18), in: rect)
        return p
    }
}

/// Back chevron used by the sheet header when a sub-pane is open.
struct BackChevronShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        smove(&p, CGPoint(x: 15, y: 6), in: rect)
        sline(&p, CGPoint(x: 9, y: 12), in: rect)
        sline(&p, CGPoint(x: 15, y: 18), in: rect)
        return p
    }
}

/// Forward chevron used as the trailing affordance on settings rows.
struct ForwardChevronShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        smove(&p, CGPoint(x: 9, y: 6), in: rect)
        sline(&p, CGPoint(x: 15, y: 12), in: rect)
        sline(&p, CGPoint(x: 9, y: 18), in: rect)
        return p
    }
}

/// Plus glyph used by the "Add model endpoint" dashed-border CTA.
struct PlusGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        smove(&p, CGPoint(x: 12, y: 5), in: rect)
        sline(&p, CGPoint(x: 12, y: 19), in: rect)
        smove(&p, CGPoint(x: 5, y: 12), in: rect)
        sline(&p, CGPoint(x: 19, y: 12), in: rect)
        return p
    }
}

/// Check glyph used to indicate selection in radio-style rows.
struct CheckGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        smove(&p, CGPoint(x: 5, y: 13), in: rect)
        sline(&p, CGPoint(x: 9, y: 17), in: rect)
        sline(&p, CGPoint(x: 19, y: 7), in: rect)
        return p
    }
}

// MARK: - Row-leading glyphs (mirrors `iconFor` in settings.jsx)

/// Profile glyph (head + shoulders) — used by the account chip when shown
/// as an avatar (the actual chip in MVP renders as a plain text card).
struct ProfileGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = 4.0 / 24 * rect.width
        let c = sscale(CGPoint(x: 12, y: 8), in: rect)
        p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        // Shoulders arc — match the SVG's "M4 21 a 8 8 0 0 1 16 0" by
        // approximating with a quad curve through the apex.
        let left = sscale(CGPoint(x: 4, y: 21), in: rect)
        let right = sscale(CGPoint(x: 20, y: 21), in: rect)
        let apex = sscale(CGPoint(x: 12, y: 13.5), in: rect)
        p.move(to: left)
        p.addQuadCurve(to: right, control: apex)
        return p
    }
}

/// Diamond/cube — Models pane.
struct ModelsGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        smove(&p, CGPoint(x: 12, y: 3), in: rect)
        sline(&p, CGPoint(x: 21, y: 8), in: rect)
        sline(&p, CGPoint(x: 12, y: 13), in: rect)
        sline(&p, CGPoint(x: 3, y: 8), in: rect)
        sline(&p, CGPoint(x: 12, y: 3), in: rect)
        smove(&p, CGPoint(x: 3, y: 13), in: rect)
        sline(&p, CGPoint(x: 12, y: 18), in: rect)
        sline(&p, CGPoint(x: 21, y: 13), in: rect)
        return p
    }
}

/// Crescent moon — Theme pane.
struct ThemeGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Approximation of the SVG's `M21 12.8 A9 9 0 1 1 11.2 3 a7 7 0 0 0
        // 9.8 9.8z` — outer crescent + inner cutout via two arcs.
        let cOuter = sscale(CGPoint(x: 12, y: 12), in: rect)
        let rOuter = 9.0 / 24 * rect.width
        p.addArc(
            center: cOuter,
            radius: rOuter,
            startAngle: .degrees(-30),
            endAngle: .degrees(210),
            clockwise: false
        )
        // Bite — small inner arc starting at the top right
        let cInner = sscale(CGPoint(x: 16, y: 8), in: rect)
        let rInner = 7.0 / 24 * rect.width
        p.addArc(
            center: cInner,
            radius: rInner,
            startAngle: .degrees(160),
            endAngle: .degrees(70),
            clockwise: true
        )
        p.closeSubpath()
        return p
    }
}

/// Three horizontal lines — System Prompt pane.
struct PromptGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        smove(&p, CGPoint(x: 4, y: 6), in: rect)
        sline(&p, CGPoint(x: 20, y: 6), in: rect)
        smove(&p, CGPoint(x: 4, y: 12), in: rect)
        sline(&p, CGPoint(x: 14, y: 12), in: rect)
        smove(&p, CGPoint(x: 4, y: 18), in: rect)
        sline(&p, CGPoint(x: 20, y: 18), in: rect)
        return p
    }
}

/// Two linked circles — Default Verbosity pane.
struct VerbosityGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = 3.0 / 24 * rect.width
        let topLeft = sscale(CGPoint(x: 8, y: 8), in: rect)
        let bottomRight = sscale(CGPoint(x: 16, y: 16), in: rect)
        p.addEllipse(in: CGRect(x: topLeft.x - r, y: topLeft.y - r, width: r * 2, height: r * 2))
        p.addEllipse(in: CGRect(x: bottomRight.x - r, y: bottomRight.y - r, width: r * 2, height: r * 2))
        // Connector — `M8 11v5a3 3 0 0 0 3 3h2`
        smove(&p, CGPoint(x: 8, y: 11), in: rect)
        sline(&p, CGPoint(x: 8, y: 16), in: rect)
        let armEnd = sscale(CGPoint(x: 13, y: 19), in: rect)
        let arm = sscale(CGPoint(x: 8, y: 19), in: rect)
        p.addQuadCurve(to: armEnd, control: arm)
        return p
    }
}

/// Window-pane grid — Appearance pane.
struct AppearanceGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let frame = CGRect(
            x: rect.minX + 4 / 24 * rect.width,
            y: rect.minY + 4 / 24 * rect.height,
            width: 16 / 24 * rect.width,
            height: 16 / 24 * rect.height
        )
        p.addRect(frame)
        smove(&p, CGPoint(x: 4, y: 10), in: rect)
        sline(&p, CGPoint(x: 20, y: 10), in: rect)
        smove(&p, CGPoint(x: 10, y: 4), in: rect)
        sline(&p, CGPoint(x: 10, y: 20), in: rect)
        return p
    }
}

/// Wrench glyph — Tools pane.
///
/// Bespoke: not in `settings.jsx`'s `iconFor` block. The Settings sheet
/// gained the Tools pane in M9 to surface tool enablement, and the icon
/// is hand-tuned to match the visual weight of the other 22pt row glyphs.
struct ToolsGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Stylized wrench: slanted handle + open-jaw head.
        smove(&p, CGPoint(x: 14, y: 7), in: rect)
        // Head loop (open-ended). Quad curve from current pen to (18,11)
        // via (20,5) gives the round-nosed top half; the next two
        // segments + close paint the open jaw.
        let headEnd = sscale(CGPoint(x: 18, y: 11), in: rect)
        let headControl = sscale(CGPoint(x: 20, y: 5), in: rect)
        p.addQuadCurve(to: headEnd, control: headControl)
        sline(&p, CGPoint(x: 16, y: 13), in: rect)
        let openEnd = sscale(CGPoint(x: 12, y: 9), in: rect)
        let openControl = sscale(CGPoint(x: 12, y: 13), in: rect)
        p.addQuadCurve(to: openEnd, control: openControl)
        sline(&p, CGPoint(x: 14, y: 7), in: rect)
        // Handle — diagonal
        smove(&p, CGPoint(x: 14, y: 13), in: rect)
        sline(&p, CGPoint(x: 6, y: 21), in: rect)
        sline(&p, CGPoint(x: 4, y: 19), in: rect)
        sline(&p, CGPoint(x: 12, y: 11), in: rect)
        return p
    }
}

/// Compaction glyph — two arrows pointing inward (mirrors a "compress"
/// affordance from the design palette). 24-unit canvas mirrored for both
/// halves so the icon stays symmetrical.
struct CompactionGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Outer brackets — top + bottom
        smove(&p, CGPoint(x: 5, y: 4), in: rect)
        sline(&p, CGPoint(x: 5, y: 8), in: rect)
        sline(&p, CGPoint(x: 9, y: 8), in: rect)
        smove(&p, CGPoint(x: 19, y: 4), in: rect)
        sline(&p, CGPoint(x: 19, y: 8), in: rect)
        sline(&p, CGPoint(x: 15, y: 8), in: rect)
        smove(&p, CGPoint(x: 5, y: 20), in: rect)
        sline(&p, CGPoint(x: 5, y: 16), in: rect)
        sline(&p, CGPoint(x: 9, y: 16), in: rect)
        smove(&p, CGPoint(x: 19, y: 20), in: rect)
        sline(&p, CGPoint(x: 19, y: 16), in: rect)
        sline(&p, CGPoint(x: 15, y: 16), in: rect)
        // Center line
        smove(&p, CGPoint(x: 4, y: 12), in: rect)
        sline(&p, CGPoint(x: 20, y: 12), in: rect)
        return p
    }
}

/// Cylinder/database — Data pane.
struct DataGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Top ellipse
        let cx = rect.midX
        let topY = rect.minY + 6 / 24 * rect.height
        let rxOuter = 8.0 / 24 * rect.width
        let ry = 3.0 / 24 * rect.height
        p.addEllipse(in: CGRect(x: cx - rxOuter, y: topY - ry, width: rxOuter * 2, height: ry * 2))
        // Sides
        let bottomY = rect.minY + 18 / 24 * rect.height
        smove(&p, CGPoint(x: 4, y: 6), in: rect)
        sline(&p, CGPoint(x: 4, y: 18), in: rect)
        let arc1End = CGPoint(x: cx + rxOuter, y: bottomY)
        let arc1Control = CGPoint(x: cx, y: bottomY + ry)
        p.addQuadCurve(to: arc1End, control: arc1Control)
        sline(&p, CGPoint(x: 20, y: 6), in: rect)
        // Mid divider — implies a record set
        let midY = rect.minY + 12 / 24 * rect.height
        smove(&p, CGPoint(x: 4, y: 12), in: rect)
        let midEnd = CGPoint(x: cx + rxOuter, y: midY)
        let midControl = CGPoint(x: cx, y: midY + ry)
        p.addQuadCurve(to: midEnd, control: midControl)
        return p
    }
}

/// Info circle — About pane.
struct AboutGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let center = sscale(CGPoint(x: 12, y: 12), in: rect)
        let r = 9.0 / 24 * rect.width
        p.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        // i-stem
        let dot = sscale(CGPoint(x: 12, y: 8), in: rect)
        let dotR = 0.6 / 24 * rect.width
        p.addEllipse(in: CGRect(x: dot.x - dotR, y: dot.y - dotR, width: dotR * 2, height: dotR * 2))
        smove(&p, CGPoint(x: 11, y: 12), in: rect)
        sline(&p, CGPoint(x: 12, y: 12), in: rect)
        sline(&p, CGPoint(x: 12, y: 17), in: rect)
        sline(&p, CGPoint(x: 13, y: 17), in: rect)
        return p
    }
}

// MARK: - Public icon views

struct CloseGlyph: View {
    let size: CGFloat
    init(size: CGFloat = 16) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: CloseGlyphShape(), size: size, lineWidth: 1.6)
    }
}

struct BackChevron: View {
    let size: CGFloat
    init(size: CGFloat = 18) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: BackChevronShape(), size: size, lineWidth: 1.7)
    }
}

struct ForwardChevron: View {
    let size: CGFloat
    init(size: CGFloat = 14) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: ForwardChevronShape(), size: size, lineWidth: 1.8)
    }
}

struct PlusGlyph: View {
    let size: CGFloat
    init(size: CGFloat = 14) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: PlusGlyphShape(), size: size, lineWidth: 1.7)
    }
}

struct CheckGlyph: View {
    let size: CGFloat
    init(size: CGFloat = 16) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: CheckGlyphShape(), size: size, lineWidth: 2.0)
    }
}

struct ModelsGlyph: View {
    let size: CGFloat
    init(size: CGFloat = 22) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: ModelsGlyphShape(), size: size, lineWidth: 1.5)
    }
}

struct ThemeGlyph: View {
    let size: CGFloat
    init(size: CGFloat = 22) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: ThemeGlyphShape(), size: size, lineWidth: 1.5)
    }
}

struct PromptGlyph: View {
    let size: CGFloat
    init(size: CGFloat = 22) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: PromptGlyphShape(), size: size, lineWidth: 1.5)
    }
}

struct VerbosityGlyph: View {
    let size: CGFloat
    init(size: CGFloat = 22) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: VerbosityGlyphShape(), size: size, lineWidth: 1.5)
    }
}

struct AppearanceGlyph: View {
    let size: CGFloat
    init(size: CGFloat = 22) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: AppearanceGlyphShape(), size: size, lineWidth: 1.5)
    }
}

struct ToolsGlyph: View {
    let size: CGFloat
    init(size: CGFloat = 22) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: ToolsGlyphShape(), size: size, lineWidth: 1.5)
    }
}

struct CompactionGlyph: View {
    let size: CGFloat
    init(size: CGFloat = 22) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: CompactionGlyphShape(), size: size, lineWidth: 1.5)
    }
}

struct DataGlyph: View {
    let size: CGFloat
    init(size: CGFloat = 22) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: DataGlyphShape(), size: size, lineWidth: 1.5)
    }
}

struct AboutGlyph: View {
    let size: CGFloat
    init(size: CGFloat = 22) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: AboutGlyphShape(), size: size, lineWidth: 1.5)
    }
}
