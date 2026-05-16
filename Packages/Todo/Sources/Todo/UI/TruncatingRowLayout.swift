import SwiftUI

/// Single-line `Layout` for the task row's meta line: label chips followed
/// by a pinned trailing badge (the due date). Chips are placed at their
/// natural width — never compressed, so their text can't wrap — and when
/// they overflow the available width the overflow is dropped and a trailing
/// ellipsis marker is shown just before the pinned badge.
///
/// The content closure must supply, in order: zero or more chip subviews,
/// then the ellipsis marker, then the trailing badge (pass a zero-size view
/// when there is no badge). The marker is parked off-screen whenever every
/// chip fits.
struct TruncatingRowLayout: Layout {
    var spacing: CGFloat = 5

    /// Natural (unconstrained) size of every subview, measured once when the
    /// subviews change and reused by both `sizeThatFits` and `placeSubviews`
    /// so a layout pass never re-measures the same chip.
    struct SizeCache {
        var natural: [CGSize]
    }

    func makeCache(subviews: Subviews) -> SizeCache {
        SizeCache(natural: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout SizeCache, subviews: Subviews) {
        cache.natural = subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout SizeCache) -> CGSize {
        let sizes = cache.natural
        let height = sizes.map(\.height).max() ?? 0
        // Real layout always arrives with a concrete width — the enclosing
        // task-row `HStack` bounds it — and the row simply claims it (it
        // sits left-aligned in the card's `VStack`, so trailing slack is
        // harmless). The natural single-line width is returned only for an
        // unconstrained sizing query, where reporting the un-truncated ideal
        // is the correct answer. The layout never *demands* width —
        // `placeSubviews` truncates to whatever `bounds` it is handed — so,
        // unlike a plain `HStack` of chips, it cannot widen the row.
        let natural = sizes.map(\.width).reduce(0, +)
            + spacing * CGFloat(max(0, sizes.count - 1))
        return CGSize(width: proposal.width ?? natural, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout SizeCache) {
        let sizes = cache.natural
        // The caller always supplies the marker + trailing badge, so a
        // count below 2 means that contract was broken. Trap it in debug so
        // a misuse surfaces at the call site, and park everything in release
        // so a shipping build degrades to a blank meta line rather than a
        // crash.
        guard subviews.count >= 2 else {
            assertionFailure("TruncatingRowLayout requires chips…, an ellipsis marker, then a trailing badge")
            for index in subviews.indices { park(subviews[index], size: sizes[index]) }
            return
        }
        let ellipsisIndex = subviews.count - 2
        let dueIndex = subviews.count - 1

        let dueWidth = sizes[dueIndex].width
        let ellipsisWidth = sizes[ellipsisIndex].width
        // Reserve the pinned badge's width up front so a long chip set can
        // never push the due date off the row. A zero-width trailing
        // subview is the caller's "no badge" signal and reserves nothing.
        let chipBudget = bounds.width - (dueWidth > 0 ? dueWidth + spacing : 0)

        var x = bounds.minX
        var placed = 0
        for index in 0..<ellipsisIndex {
            let chipWidth = sizes[index].width
            let isLastChip = index == ellipsisIndex - 1
            // A non-final chip must also leave room for the ellipsis that
            // would follow it; the final chip only needs to fit itself.
            // The marker is always narrower than a real chip, so this never
            // drops a chip that the row could otherwise have shown.
            let reservedAfter = isLastChip ? 0 : spacing + ellipsisWidth
            guard (x - bounds.minX) + chipWidth + reservedAfter <= chipBudget else { break }
            place(subviews[index], at: x, in: bounds, size: sizes[index])
            x += chipWidth + spacing
            placed += 1
        }
        for index in placed..<ellipsisIndex {
            park(subviews[index], size: sizes[index])
        }

        if placed < ellipsisIndex {
            place(subviews[ellipsisIndex], at: x, in: bounds, size: sizes[ellipsisIndex])
            x += ellipsisWidth + spacing
        } else {
            park(subviews[ellipsisIndex], size: sizes[ellipsisIndex])
        }

        place(subviews[dueIndex], at: x, in: bounds, size: sizes[dueIndex])
    }

    /// Places `subview` at its natural size, vertically centered in the row.
    private func place(_ subview: LayoutSubview, at x: CGFloat, in bounds: CGRect, size: CGSize) {
        subview.place(
            at: CGPoint(x: x, y: bounds.minY + (bounds.height - size.height) / 2),
            anchor: .topLeading,
            proposal: ProposedViewSize(size)
        )
    }

    /// Parks an overflow subview far off the leading edge — the card's
    /// rounded-rect clip hides it. It is still placed at its natural size so
    /// it never renders in a compressed (text-wrapped) state.
    private func park(_ subview: LayoutSubview, size: CGSize) {
        subview.place(
            at: CGPoint(x: -10_000, y: 0),
            anchor: .topLeading,
            proposal: ProposedViewSize(size)
        )
    }
}
