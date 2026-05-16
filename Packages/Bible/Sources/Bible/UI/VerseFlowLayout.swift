import SwiftUI

/// The outcome of a greedy line-wrap: each item's top-left origin within the
/// flow and the total size the wrapped rows occupy.
struct VerseFlowResult: Equatable {
    let origins: [CGPoint]
    let size: CGSize
}

/// A greedy line-wrapping layout: places its subviews left-to-right and moves
/// to the next line when the next subview would overflow the proposed width.
///
/// `BibleParagraphBlock` lays each verse word out as its own subview so a word
/// can carry a tap target and a per-verse selection background; this layout
/// reflows them into a left-justified paragraph. Wrapping is greedy — the same
/// line-breaking SwiftUI's own `Text` applies to left-aligned text — so the
/// result matches a single concatenated `Text` visually.
struct VerseFlowLayout: Layout {
    /// The subviews' measured sizes, carried from `sizeThatFits` to
    /// `placeSubviews` so each word is measured once per layout pass.
    typealias Cache = [CGSize]

    /// Vertical gap between wrapped lines, in points.
    var lineSpacing: CGFloat = 5

    func makeCache(subviews: Subviews) -> Cache { [] }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        cache = measuredSizes(subviews, maxWidth: maxWidth)
        return Self.flow(itemSizes: cache, maxWidth: maxWidth, lineSpacing: lineSpacing).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        if cache.count != subviews.count {
            cache = measuredSizes(subviews, maxWidth: bounds.width)
        }
        let sizes = cache
        let result = Self.flow(itemSizes: sizes, maxWidth: bounds.width, lineSpacing: lineSpacing)
        for (index, subview) in subviews.enumerated() {
            let origin = result.origins[index]
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(sizes[index])
            )
        }
    }

    /// Each subview's size — a subview wider than the line is re-measured
    /// against `maxWidth` so it wraps its own glyphs internally rather than
    /// overflowing the trailing margin.
    private func measuredSizes(_ subviews: Subviews, maxWidth: CGFloat) -> [CGSize] {
        subviews.map { subview in
            let natural = subview.sizeThatFits(.unspecified)
            guard maxWidth.isFinite, natural.width > maxWidth else { return natural }
            return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        }
    }

    /// Greedy line-wrap arithmetic, factored out of the `Layout` callbacks so
    /// it can be unit-tested without SwiftUI's opaque `Subviews`.
    ///
    /// Items flow left-to-right, wrapping to a new line when the next item
    /// would overflow `maxWidth`. An item already wider than `maxWidth` still
    /// takes its own line rather than looping forever — callers clamp such an
    /// item's measured width so it never actually exceeds the line.
    static func flow(itemSizes: [CGSize], maxWidth: CGFloat, lineSpacing: CGFloat) -> VerseFlowResult {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for size in itemSizes {
            if x > 0, x + size.width > maxWidth {
                widestRow = max(widestRow, x)
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
        widestRow = max(widestRow, x)

        return VerseFlowResult(
            origins: origins,
            size: CGSize(
                width: maxWidth.isFinite ? maxWidth : widestRow,
                height: origins.isEmpty ? 0 : y + rowHeight
            )
        )
    }
}
