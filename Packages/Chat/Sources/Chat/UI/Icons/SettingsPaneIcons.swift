import SwiftUI

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

struct CloseIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        smove(&p, CGPoint(x: 6, y: 6), in: rect)
        sline(&p, CGPoint(x: 18, y: 18), in: rect)
        smove(&p, CGPoint(x: 18, y: 6), in: rect)
        sline(&p, CGPoint(x: 6, y: 18), in: rect)
        return p
    }
}

struct BackChevronIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        smove(&p, CGPoint(x: 15, y: 6), in: rect)
        sline(&p, CGPoint(x: 9, y: 12), in: rect)
        sline(&p, CGPoint(x: 15, y: 18), in: rect)
        return p
    }
}

struct ForwardChevronIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        smove(&p, CGPoint(x: 9, y: 6), in: rect)
        sline(&p, CGPoint(x: 15, y: 12), in: rect)
        sline(&p, CGPoint(x: 9, y: 18), in: rect)
        return p
    }
}

struct PlusIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        smove(&p, CGPoint(x: 12, y: 5), in: rect)
        sline(&p, CGPoint(x: 12, y: 19), in: rect)
        smove(&p, CGPoint(x: 5, y: 12), in: rect)
        sline(&p, CGPoint(x: 19, y: 12), in: rect)
        return p
    }
}

struct CheckIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        smove(&p, CGPoint(x: 5, y: 13), in: rect)
        sline(&p, CGPoint(x: 9, y: 17), in: rect)
        sline(&p, CGPoint(x: 19, y: 7), in: rect)
        return p
    }
}

struct ModelsIconShape: Shape {
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

struct ThemeIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Approximate the source SVG crescent with outer and inner arcs.
        let cOuter = sscale(CGPoint(x: 12, y: 12), in: rect)
        let rOuter = 9.0 / 24 * rect.width
        p.addArc(
            center: cOuter,
            radius: rOuter,
            startAngle: .degrees(-30),
            endAngle: .degrees(210),
            clockwise: false
        )
        // Inner cutout.
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

struct PromptIconShape: Shape {
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

struct VerbosityIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = 3.0 / 24 * rect.width
        let topLeft = sscale(CGPoint(x: 8, y: 8), in: rect)
        let bottomRight = sscale(CGPoint(x: 16, y: 16), in: rect)
        p.addEllipse(in: CGRect(x: topLeft.x - r, y: topLeft.y - r, width: r * 2, height: r * 2))
        p.addEllipse(in: CGRect(x: bottomRight.x - r, y: bottomRight.y - r, width: r * 2, height: r * 2))
        // Connector between the circles.
        smove(&p, CGPoint(x: 8, y: 11), in: rect)
        sline(&p, CGPoint(x: 8, y: 16), in: rect)
        let armEnd = sscale(CGPoint(x: 13, y: 19), in: rect)
        let arm = sscale(CGPoint(x: 8, y: 19), in: rect)
        p.addQuadCurve(to: armEnd, control: arm)
        return p
    }
}

struct ToolsIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        smove(&p, CGPoint(x: 14, y: 7), in: rect)
        // Rounded head and open jaw.
        let headEnd = sscale(CGPoint(x: 18, y: 11), in: rect)
        let headControl = sscale(CGPoint(x: 20, y: 5), in: rect)
        p.addQuadCurve(to: headEnd, control: headControl)
        sline(&p, CGPoint(x: 16, y: 13), in: rect)
        let openEnd = sscale(CGPoint(x: 12, y: 9), in: rect)
        let openControl = sscale(CGPoint(x: 12, y: 13), in: rect)
        p.addQuadCurve(to: openEnd, control: openControl)
        sline(&p, CGPoint(x: 14, y: 7), in: rect)
        smove(&p, CGPoint(x: 14, y: 13), in: rect)
        sline(&p, CGPoint(x: 6, y: 21), in: rect)
        sline(&p, CGPoint(x: 4, y: 19), in: rect)
        sline(&p, CGPoint(x: 12, y: 11), in: rect)
        return p
    }
}

struct CompactionIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
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
        smove(&p, CGPoint(x: 4, y: 12), in: rect)
        sline(&p, CGPoint(x: 20, y: 12), in: rect)
        return p
    }
}

struct DataIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let cx = rect.midX
        let topY = rect.minY + 6 / 24 * rect.height
        let rxOuter = 8.0 / 24 * rect.width
        let ry = 3.0 / 24 * rect.height
        p.addEllipse(in: CGRect(x: cx - rxOuter, y: topY - ry, width: rxOuter * 2, height: ry * 2))
        let bottomY = rect.minY + 18 / 24 * rect.height
        smove(&p, CGPoint(x: 4, y: 6), in: rect)
        sline(&p, CGPoint(x: 4, y: 18), in: rect)
        let arc1End = CGPoint(x: cx + rxOuter, y: bottomY)
        let arc1Control = CGPoint(x: cx, y: bottomY + ry)
        p.addQuadCurve(to: arc1End, control: arc1Control)
        sline(&p, CGPoint(x: 20, y: 6), in: rect)
        let midY = rect.minY + 12 / 24 * rect.height
        smove(&p, CGPoint(x: 4, y: 12), in: rect)
        let midEnd = CGPoint(x: cx + rxOuter, y: midY)
        let midControl = CGPoint(x: cx, y: midY + ry)
        p.addQuadCurve(to: midEnd, control: midControl)
        return p
    }
}

struct SearchIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let center = sscale(CGPoint(x: 11, y: 11), in: rect)
        let r = 6.0 / 24 * rect.width
        p.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        smove(&p, CGPoint(x: 15.5, y: 15.5), in: rect)
        sline(&p, CGPoint(x: 20, y: 20), in: rect)
        return p
    }
}

struct AboutIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let center = sscale(CGPoint(x: 12, y: 12), in: rect)
        let r = 9.0 / 24 * rect.width
        p.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
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

struct CloseIcon: View {
    let size: CGFloat
    init(size: CGFloat = 16) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: CloseIconShape(), size: size, lineWidth: 1.6)
    }
}

struct BackChevronIcon: View {
    let size: CGFloat
    init(size: CGFloat = 18) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: BackChevronIconShape(), size: size, lineWidth: 1.7)
    }
}

struct ForwardChevronIcon: View {
    let size: CGFloat
    init(size: CGFloat = 14) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: ForwardChevronIconShape(), size: size, lineWidth: 1.8)
    }
}

struct PlusIcon: View {
    let size: CGFloat
    init(size: CGFloat = 14) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: PlusIconShape(), size: size, lineWidth: 1.7)
    }
}

struct CheckIcon: View {
    let size: CGFloat
    init(size: CGFloat = 16) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: CheckIconShape(), size: size, lineWidth: 2.0)
    }
}

struct ModelsIcon: View {
    let size: CGFloat
    init(size: CGFloat = 22) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: ModelsIconShape(), size: size, lineWidth: 1.5)
    }
}

struct ThemeIcon: View {
    let size: CGFloat
    init(size: CGFloat = 22) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: ThemeIconShape(), size: size, lineWidth: 1.5)
    }
}

struct PromptIcon: View {
    let size: CGFloat
    init(size: CGFloat = 22) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: PromptIconShape(), size: size, lineWidth: 1.5)
    }
}

struct VerbosityIcon: View {
    let size: CGFloat
    init(size: CGFloat = 22) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: VerbosityIconShape(), size: size, lineWidth: 1.5)
    }
}

struct ToolsIcon: View {
    let size: CGFloat
    init(size: CGFloat = 22) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: ToolsIconShape(), size: size, lineWidth: 1.5)
    }
}

struct CompactionIcon: View {
    let size: CGFloat
    init(size: CGFloat = 22) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: CompactionIconShape(), size: size, lineWidth: 1.5)
    }
}

struct DataIcon: View {
    let size: CGFloat
    init(size: CGFloat = 22) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: DataIconShape(), size: size, lineWidth: 1.5)
    }
}

struct SearchIcon: View {
    let size: CGFloat
    init(size: CGFloat = 22) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: SearchIconShape(), size: size, lineWidth: 1.5)
    }
}

struct AboutIcon: View {
    let size: CGFloat
    init(size: CGFloat = 22) { self.size = size }
    var body: some View {
        StrokedGlyph(shape: AboutIconShape(), size: size, lineWidth: 1.5)
    }
}
