import SwiftUI

/// The outcome of a greedy line-wrap: each item's placement origin within the
/// flow (top-leading anchor; text items baseline-aligned within their row,
/// baseline-less glyphs vertically centred) and the total size the wrapped
/// rows occupy.
struct VerseFlowResult: Equatable {
    let origins: [CGPoint]
    let size: CGSize
}

/// Marks a flow cell that should sit vertically *centred* in its row rather
/// than baseline-aligned with the row's text. Set on the trailing annotation /
/// note glyphs — they carry no meaningful text baseline, so centring keeps
/// them mid-line beside taller verse text. Words leave it at the default
/// (`false`) so they baseline-align.
struct CentersInRowKey: LayoutValueKey {
    static let defaultValue = false
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
    /// The subviews' measured sizes and first-text baselines plus the width
    /// they were measured at, carried from `sizeThatFits` to `placeSubviews`
    /// so each word is measured once per layout pass. Keyed by width because
    /// the over-wide clamp in `measuredSizes` is width-dependent — a stale
    /// cache from a different proposed width would mis-place a clamped subview.
    struct Cache {
        var maxWidth: CGFloat
        var sizes: [CGSize]
        /// Each item's first-text baseline as a distance from its box top, or
        /// `nil` for a cell flagged `CentersInRowKey` (centred, not aligned).
        var baselines: [CGFloat?]
    }

    /// Vertical gap between wrapped lines, in points.
    var lineSpacing: CGFloat = 5

    func makeCache(subviews: Subviews) -> Cache {
        Cache(maxWidth: .nan, sizes: [], baselines: [])
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let metrics = cachedMetrics(subviews, maxWidth: maxWidth, cache: &cache)
        return Self.flow(
            itemSizes: metrics.sizes,
            baselines: metrics.baselines,
            maxWidth: maxWidth,
            lineSpacing: lineSpacing
        ).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let metrics = cachedMetrics(subviews, maxWidth: bounds.width, cache: &cache)
        let result = Self.flow(
            itemSizes: metrics.sizes,
            baselines: metrics.baselines,
            maxWidth: bounds.width,
            lineSpacing: lineSpacing
        )
        for (index, subview) in subviews.enumerated() {
            let origin = result.origins[index]
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(metrics.sizes[index])
            )
        }
    }

    /// The subviews' sizes and baselines for `maxWidth`, reusing the cache only
    /// when it was filled at the same width — and subview count — so a pass
    /// with a different proposed width re-measures rather than placing with
    /// stale, possibly mis-clamped sizes.
    private func cachedMetrics(_ subviews: Subviews, maxWidth: CGFloat, cache: inout Cache) -> (sizes: [CGSize], baselines: [CGFloat?]) {
        if cache.maxWidth == maxWidth, cache.sizes.count == subviews.count {
            return (cache.sizes, cache.baselines)
        }
        let sizes = measuredSizes(subviews, maxWidth: maxWidth)
        let baselines: [CGFloat?] = subviews.enumerated().map { index, subview in
            guard !subview[CentersInRowKey.self] else { return nil }
            return subview.dimensions(in: ProposedViewSize(sizes[index]))[.firstTextBaseline]
        }
        cache = Cache(maxWidth: maxWidth, sizes: sizes, baselines: baselines)
        return (sizes, baselines)
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
    ///
    /// `baselines[i]` is item `i`'s first-text baseline measured from its box
    /// top, or `nil` to centre that item in its row instead (a trailing glyph
    /// with no meaningful text baseline). A short or empty `baselines` treats
    /// the unspecified items as centred — so a caller passing only `itemSizes`
    /// gets pure box-centring.
    static func flow(
        itemSizes: [CGSize],
        baselines: [CGFloat?] = [],
        maxWidth: CGFloat,
        lineSpacing: CGFloat
    ) -> VerseFlowResult {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0
        var rowStart = 0

        func baseline(_ i: Int) -> CGFloat? {
            i < baselines.count ? baselines[i] : nil
        }

        // Align the just-finished row. Text items (those carrying a baseline)
        // drop so every baseline coincides at the row's lowest one, keeping all
        // words on a single line however much a raised verse-number marker
        // inflates its word's box. Items with no baseline — the trailing glyphs
        // — centre vertically instead, sitting mid-line beside the verse text.
        // A row of equal-height, equal-baseline words gets all-zero offsets, so
        // a plain word-only row is left untouched.
        func alignRow(end: Int) {
            var rowBaseline: CGFloat?
            for i in rowStart..<end {
                if let b = baseline(i) {
                    rowBaseline = max(rowBaseline ?? b, b)
                }
            }
            for i in rowStart..<end {
                if let b = baseline(i), let rowBaseline {
                    origins[i].y += rowBaseline - b
                } else {
                    origins[i].y += (rowHeight - itemSizes[i].height) / 2
                }
            }
        }

        for size in itemSizes {
            if x > 0, x + size.width > maxWidth {
                alignRow(end: origins.count)
                widestRow = max(widestRow, x)
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
                rowStart = origins.count
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
        alignRow(end: origins.count)
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
