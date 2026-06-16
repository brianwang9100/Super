import Core
import SwiftUI

/// The ribbon-bookmark glyph that marks a chapter as carrying one of the six
/// colour bookmarks.
///
/// Deliberately neither the annotation speech bubble nor the note page: a
/// bookmark is a physical ribbon laid into the book. The three glyphs share
/// the 24×24 design grid, the `1.6` stroke, and rounded caps/joins so they
/// sit together cleanly in the chapter-title cluster, but read as distinct
/// shapes.
///
/// Three states drive the silhouette:
///
/// - `.filled(color)` — solid ribbon in the bookmark colour's theme-aware
///   tint; shown when the chapter holds that colour's bookmark.
/// - `.unassigned(color)` — pale `softTint` fill with the opaque `tint` as the
///   outline; the bookmark sheet's and Bookmarks applet's empty slot cards, so
///   an empty slot still reads as its colour rather than a generic grey.
/// - `.outline` — `inkFaint` stroke; the tap-to-assign affordance on an
///   unbookmarked chapter, where no colour is assigned to tint.
///
/// The shape is a hand-drawn `Path` rather than an SF Symbol so the ribbon's
/// proportions and notch depth match the sibling glyphs' design grid.
struct BookmarkGlyph: View {
    @Environment(\.superTheme) private var theme

    /// Named `GlyphState` rather than `State` to avoid shadowing
    /// `SwiftUI.State` within this struct's scope — the same rationale
    /// `NoteGlyph.GlyphState` follows.
    enum GlyphState: Sendable, Equatable {
        case filled(BibleBookmarkColor)
        case unassigned(BibleBookmarkColor)
        case outline
    }

    let state: GlyphState
    let size: CGFloat

    init(state: GlyphState = .outline, size: CGFloat = 16) {
        self.state = state
        self.size = size
    }

    /// Horizontal ink bounds in 24-unit design coordinates, padded by the
    /// half stroke width (`1.6 / 2`) so round joins aren't clipped — the
    /// `NoteGlyph` side-bearing technique. The ribbon spans x 6…18, centred
    /// on x=12.
    private static let inkMinX: CGFloat = 5.2   // ribbon left (6) − half stroke
    private static let inkMaxX: CGFloat = 18.8  // ribbon right (18) + half stroke

    var body: some View {
        let scale = size / 24.0
        let inkWidth = (Self.inkMaxX - Self.inkMinX) * scale
        return Canvas { context, _ in
            context.translateBy(x: -Self.inkMinX * scale, y: 0)
            let ribbon = ribbonPath(scale: scale)
            switch state {
            case .filled(let color):
                let tint = color.tint(forDarkTheme: theme.isDark).color
                context.fill(ribbon, with: .color(tint))
                // Stroke in the fill colour too so filled and outline states
                // render the same overall size (a stroke straddles the path).
                context.stroke(ribbon, with: .color(tint), style: stroke(scale: scale))
            case .unassigned(let color):
                // Pale fill + full-tint outline: the empty slot reads as its
                // colour while staying clearly distinct from the solid filled
                // ribbon (which differs only in the fill being opaque).
                let fill = color.softTint(forDarkTheme: theme.isDark).color
                let edge = color.tint(forDarkTheme: theme.isDark).color
                context.fill(ribbon, with: .color(fill))
                context.stroke(ribbon, with: .color(edge), style: stroke(scale: scale))
            case .outline:
                context.stroke(ribbon, with: .color(theme.inkFaint), style: stroke(scale: scale))
            }
        }
        .frame(width: inkWidth, height: size)
        .accessibilityHidden(true)
    }

    private func stroke(scale: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: 1.6 * scale, lineCap: .round, lineJoin: .round)
    }

    /// The ribbon body: rounded top corners (radius 2), straight sides, and
    /// a bottom notch rising to the centre — `M6 20.8 V5.4 a2 2 → 8 3.4 H16
    /// a2 2 → 18 5.4 V20.8 L12 16.2 z` on the 24-unit grid.
    private func ribbonPath(scale: CGFloat) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }
        var path = Path()
        path.move(to: p(6, 20.8))
        path.addLine(to: p(6, 5.4))
        path.addArc(tangent1End: p(6, 3.4), tangent2End: p(8, 3.4), radius: 2 * scale)
        path.addLine(to: p(16, 3.4))
        path.addArc(tangent1End: p(18, 3.4), tangent2End: p(18, 5.4), radius: 2 * scale)
        path.addLine(to: p(18, 20.8))
        path.addLine(to: p(12, 16.2))
        path.closeSubpath()
        return path
    }
}
