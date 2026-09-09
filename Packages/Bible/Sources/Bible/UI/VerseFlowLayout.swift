import SwiftUI

/// Origins use top-leading coordinates, with text baselines aligned and glyphs centered per row.
struct VerseFlowResult: Equatable {
    let origins: [CGPoint]
    let size: CGSize
}

/// Marks baseline-less glyphs for vertical centering; words retain baseline alignment.
struct CentersInRowKey: LayoutValueKey {
    static let defaultValue = false
}

struct VerseFlowLayout: Layout {
    // Cache by width because over-wide word measurements depend on the proposal.
    struct Cache {
        var maxWidth: CGFloat
        var sizes: [CGSize]
        /// Distance from box top, or nil for a centered glyph.
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

    // Remeasure over-wide words at the line width so their glyphs wrap within the margin.
    private func measuredSizes(_ subviews: Subviews, maxWidth: CGFloat) -> [CGSize] {
        subviews.map { subview in
            let natural = subview.sizeThatFits(.unspecified)
            guard maxWidth.isFinite, natural.width > maxWidth else { return natural }
            return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        }
    }

    /// Greedy wrapping gives an over-wide item its own line. Missing/nil baseline
    /// entries center their cells; supplied baselines are distances from box tops.
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

        // Align text to the lowest baseline, including marker-inflated words; center glyphs separately.
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
