import SwiftUI
import Testing
@testable import Bible

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

    @Test("text items in a row align on a shared baseline, not on box centre")
    func baselineAlignsTextItems() {
        // Raised verse numbers inflate the word box. Aligning baselines must lower its
        // shorter neighbor by 6pt, not the 3pt from box-centering that broke minimum-scale text.
        let result = VerseFlowLayout.flow(
            itemSizes: [CGSize(width: 40, height: 20), CGSize(width: 30, height: 14)],
            baselines: [16, 10],
            maxWidth: 100,
            lineSpacing: 5
        )
        #expect(result.origins == [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 6)])
        #expect(result.size.height == 20)
    }

    @Test("a baseline-less item centres while its text neighbours baseline-align")
    func centresBaselinelessItemBesideText() {
        // Glyphs without text baselines must remain box-centered beside taller words.
        let result = VerseFlowLayout.flow(
            itemSizes: [CGSize(width: 40, height: 20), CGSize(width: 18, height: 18)],
            baselines: [16, nil],
            maxWidth: 100,
            lineSpacing: 5
        )
        #expect(result.origins == [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 1)])
    }

    @Test("vertical centering is computed per row, independently across a wrap")
    func centersPerRowAcrossWrap() {
        // The wrapped row must center against its own height, not an earlier row's.
        let result = VerseFlowLayout.flow(
            itemSizes: [
                CGSize(width: 40, height: 10),
                CGSize(width: 40, height: 20),
                CGSize(width: 40, height: 12)
            ],
            maxWidth: 100,
            lineSpacing: 5
        )
        #expect(result.origins[0] == CGPoint(x: 0, y: 5))
        #expect(result.origins[1] == CGPoint(x: 40, y: 0))
        #expect(result.origins[2] == CGPoint(x: 0, y: 25))
        #expect(result.size.height == 37)
    }
}
