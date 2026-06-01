import SwiftUI
import Testing
@testable import Bible

/// Tests for `VerseFlowLayout.flow` — the greedy line-wrap arithmetic behind
/// the tappable verse renderer, exercised directly with item sizes so no
/// SwiftUI host is needed.
@Suite("VerseFlowLayout")
struct VerseFlowLayoutTests {
    @Test("an empty flow has no origins and zero height")
    func emptyFlow() {
        let result = VerseFlowLayout.flow(itemSizes: [], maxWidth: 100, lineSpacing: 5)
        #expect(result.origins.isEmpty)
        #expect(result.size.height == 0)
    }

    @Test("items that fit share one row, the tallest sets the height, shorter items centre vertically")
    func singleRow() {
        let result = VerseFlowLayout.flow(
            itemSizes: [CGSize(width: 30, height: 10), CGSize(width: 40, height: 12)],
            maxWidth: 100,
            lineSpacing: 5
        )
        // Row height is 12 (the taller item); the 10-tall item drops by
        // (12 - 10) / 2 = 1 so it sits centred on the line, not pinned to the top.
        #expect(result.origins == [CGPoint(x: 0, y: 1), CGPoint(x: 30, y: 0)])
        #expect(result.size.height == 12)
    }

    @Test("an overflowing item wraps to the next row, offset by line spacing")
    func wrapsOnOverflow() {
        let result = VerseFlowLayout.flow(
            itemSizes: [CGSize(width: 60, height: 10), CGSize(width: 60, height: 14)],
            maxWidth: 100,
            lineSpacing: 5
        )
        #expect(result.origins[0] == CGPoint(x: 0, y: 0))
        // Second row starts below the first row's height plus the line gap.
        #expect(result.origins[1] == CGPoint(x: 0, y: 15))
        #expect(result.size.height == 29)
    }

    @Test("an unbounded proposal reports the widest row as the flow width")
    func unboundedWidthTracksWidestRow() {
        let result = VerseFlowLayout.flow(
            itemSizes: [CGSize(width: 30, height: 10), CGSize(width: 70, height: 10)],
            maxWidth: .infinity,
            lineSpacing: 5
        )
        #expect(result.size.width == 100)
    }

    @Test("an item wider than the line still takes its own row instead of looping")
    func overWideItemGetsOwnRow() {
        let result = VerseFlowLayout.flow(
            itemSizes: [CGSize(width: 40, height: 10), CGSize(width: 200, height: 10)],
            maxWidth: 100,
            lineSpacing: 5
        )
        #expect(result.origins[1] == CGPoint(x: 0, y: 15))
    }

    @Test("vertical centering is computed per row, independently across a wrap")
    func centersPerRowAcrossWrap() {
        // Row 1 holds two items (40+40 ≤ 100); the third wraps. The shorter
        // first item centres within row 1's height (20), while the wrapped
        // third item centres within its own row — proving the row-start index
        // resets at the wrap rather than centring against an earlier row.
        let result = VerseFlowLayout.flow(
            itemSizes: [
                CGSize(width: 40, height: 10),
                CGSize(width: 40, height: 20),
                CGSize(width: 40, height: 12)
            ],
            maxWidth: 100,
            lineSpacing: 5
        )
        // Row 1 height 20: item 0 drops (20-10)/2 = 5; item 1 (the tallest) stays at 0.
        #expect(result.origins[0] == CGPoint(x: 0, y: 5))
        #expect(result.origins[1] == CGPoint(x: 40, y: 0))
        // Row 2 starts at 20 + 5 spacing = 25; its lone item gets a zero offset.
        #expect(result.origins[2] == CGPoint(x: 0, y: 25))
        #expect(result.size.height == 37)
    }
}
