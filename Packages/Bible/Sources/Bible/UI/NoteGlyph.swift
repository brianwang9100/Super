import Core
import SwiftUI

/// The folded-page glyph that marks a book / chapter / verse as carrying
/// at least one note.
///
/// Deliberately *not* the annotation speech bubble: annotations are
/// machine-spoken study cards (→ `AnnotationBubble`); notes are something
/// the reader (or the assistant) writes down (→ a small page with a
/// turned-down corner and two ruled lines). The two glyphs share the 24×24
/// design grid, the `1.6` stroke, and rounded caps/joins so they sit
/// together cleanly in `VerseTrailers`, but read as distinct shapes.
///
/// Two states drive the silhouette:
///
/// - `.filled` — solid-`accent` page with the crease + rules knocked in
///   with `accentInk`; the only in-product state, since the glyph appears
///   only once a target has ≥1 note row.
/// - `.outline` — `inkFaint` stroke; the tap-to-add affordance reused by
///   the list sheet's empty-state hero (and, in PR3, chapter titles and
///   book-picker rows).
///
/// The shape is a hand-drawn `Path` rather than an SF Symbol because no
/// SF Symbol matches the design's page proportions or fold angle. Stroke
/// width is `1.6` of a 24-unit viewbox, scaled to the caller's `size`,
/// matching the design canvas's grid exactly (`notes/atoms.jsx`).
struct NoteGlyph: View {
    @Environment(\.superTheme) private var theme

    /// Named `GlyphState` rather than `State` to avoid shadowing
    /// `SwiftUI.State` within this struct's scope — the same rationale
    /// `AnnotationBubble.BubbleState` follows.
    enum GlyphState: Sendable, Equatable {
        case filled
        case outline
    }

    let state: GlyphState
    let size: CGFloat

    init(state: GlyphState = .filled, size: CGFloat = 16) {
        self.state = state
        self.size = size
    }

    /// Horizontal ink bounds in 24-unit design coordinates, padded by the
    /// half stroke width (`1.6 / 2`) so round joins aren't clipped. The frame
    /// hugs this range rather than the full 24-unit square, so the glyph
    /// carries no empty side-bearing and adjacent glyphs gap by exactly the
    /// layout spacing. The range is centred on x=12, so single / centred
    /// placements render identically to the old square frame.
    private static let inkMinX: CGFloat = 4.2   // page left (5) − half stroke
    private static let inkMaxX: CGFloat = 19.8  // page right (19) + half stroke

    var body: some View {
        let scale = size / 24.0
        let inkWidth = (Self.inkMaxX - Self.inkMinX) * scale
        return Canvas { context, _ in
            // Vertical mapping stays on the full 24-unit grid (frame height is
            // `size`); shift left so the ink range sits flush in the trimmed
            // width.
            context.translateBy(x: -Self.inkMinX * scale, y: 0)
            let page = pagePath(scale: scale)
            let detail = detailPath(scale: scale)
            switch state {
            case .filled:
                context.fill(page, with: .color(theme.accent))
                // Stroke the page in the fill colour too: a stroke straddles
                // the path (extends ~half its width beyond the edge), so the
                // outlined state reads slightly larger than a fill-only shape.
                // Matching the stroke keeps filled and outline glyphs the same
                // size.
                context.stroke(page, with: .color(theme.accent), style: stroke(scale: scale))
                // Crease + rules knocked into the page in accentInk so the
                // glyph still reads as a written note at body-trailing size.
                context.stroke(
                    detail,
                    with: .color(theme.accentInk.opacity(0.85)),
                    style: stroke(scale: scale)
                )
            case .outline:
                context.stroke(page, with: .color(theme.inkFaint), style: stroke(scale: scale))
                context.stroke(detail, with: .color(theme.inkFaint), style: stroke(scale: scale))
            }
        }
        .frame(width: inkWidth, height: size)
        .accessibilityHidden(true)
    }

    private func stroke(scale: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: 1.6 * scale, lineCap: .round, lineJoin: .round)
    }

    /// The page body from `notes/atoms.jsx`:
    /// `M14 3.4 H7 a2 2 0 0 0 -2 2 V18.6 a2 2 0 0 0 2 2 H17 a2 2 0 0 0 2 -2
    /// V8.4 z`, scaled into the canvas. The closing segment runs the
    /// diagonal fold cut from `(19, 8.4)` back up to `(14, 3.4)`.
    private func pagePath(scale: CGFloat) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }
        var path = Path()
        path.move(to: p(14, 3.4))
        path.addLine(to: p(7, 3.4))                                   // H7
        path.addArc(tangent1End: p(5, 3.4), tangent2End: p(5, 5.4), radius: 2 * scale)
        path.addLine(to: p(5, 18.6))                                  // V18.6
        path.addArc(tangent1End: p(5, 20.6), tangent2End: p(7, 20.6), radius: 2 * scale)
        path.addLine(to: p(17, 20.6))                                 // H17
        path.addArc(tangent1End: p(19, 20.6), tangent2End: p(19, 18.6), radius: 2 * scale)
        path.addLine(to: p(19, 8.4))                                  // V8.4
        path.closeSubpath()                                           // diagonal fold cut
        return path
    }

    /// The turned-down corner crease + two ruled lines, stroked over the
    /// page: fold `M14 3.4 V6.8 a1.6 1.6 0 0 0 1.6 1.6 H19`, rules
    /// `M8.6 13 H15.4` and `M8.6 16.2 H15.4`.
    private func detailPath(scale: CGFloat) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }
        var path = Path()
        // Fold crease.
        path.move(to: p(14, 3.4))
        path.addLine(to: p(14, 6.8))                                  // V6.8
        path.addArc(tangent1End: p(14, 8.4), tangent2End: p(15.6, 8.4), radius: 1.6 * scale)
        path.addLine(to: p(19, 8.4))                                  // H19
        // Ruled lines.
        path.move(to: p(8.6, 13))
        path.addLine(to: p(15.4, 13))
        path.move(to: p(8.6, 16.2))
        path.addLine(to: p(15.4, 16.2))
        return path
    }
}
