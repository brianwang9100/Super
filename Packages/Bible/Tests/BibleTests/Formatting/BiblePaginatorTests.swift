import Core
import CoreText
import SwiftUI
import Testing
@testable import Bible

@Suite("Bible pagination")
@MainActor
struct BiblePaginatorTests {
    private func document(_ paragraphs: [BibleParagraph], decorations: BiblePageDocument.Decorations = .init()) -> BiblePageDocument {
        let typography = SuperTypography.make(.serif)
        let context = EnvironmentValues().fontResolutionContext
        return BiblePageDocument(
            chapter: BibleChapter(number: 1, paragraphs: paragraphs),
            position: .init(bookId: "GEN", chapterNumber: 1), translation: .kjv,
            bodyFont: typography.reading(24, relativeTo: nil).resolve(in: context).ctFont,
            headingFont: typography.reading(28, relativeTo: nil).resolve(in: context).ctFont,
            numberFont: typography.font(size: 13).resolve(in: context).ctFont, decorations: decorations
        )
    }

    @Test("long chapters and a single long verse preserve every source character across pages")
    func longVerse() throws {
        let source = String(repeating: "In the beginning was the Word. ", count: 240)
        let doc = document([.prose([.init(number: 1, text: source)])])
        let pages = try BiblePaginator.paginate(doc, size: CGSize(width: 350, height: 240))
        #expect(pages.count > 4)
        let ranges = pages.flatMap(\.lines).map(\.range)
        #expect(ranges.first?.location == 0)
        for pair in zip(ranges, ranges.dropFirst()) {
            #expect(NSMaxRange(pair.0) == pair.1.location)
        }
        #expect(ranges.last.map(NSMaxRange) == doc.text.length)
        #expect(pages.dropFirst().allSatisfy { $0.locator.verseNumber == 1 && $0.locator.utf16Offset > 0 })
        #expect(pages.allSatisfy { $0.lines.allSatisfy { $0.frame.maxY <= 240.01 } })
    }

    @Test("reflow locates the same word instead of persisting a page number")
    func reflow() throws {
        let doc = document([.prose([.init(number: 1, text: String(repeating: "word ", count: 300))])])
        let small = try BiblePaginator.paginate(doc, size: .init(width: 300, height: 200))
        let locator = try #require(small.dropFirst(2).first?.locator)
        let large = try BiblePaginator.paginate(doc, size: .init(width: 500, height: 400))
        let page = try #require(large.first { $0.contains(locator, in: doc) })
        #expect(page.sourceRange.contains(doc.characterIndex(for: locator)))
    }

    @Test("poetry and repeated verse fragments retain offsets and one printed verse number")
    func fragments() throws {
        let doc = document([.poetry([.init(number: 1, text: "First line\nSecond line")]),
                            .heading("A heading"), .prose([.init(number: 1, text: "Continuation.")]),])
        #expect(doc.verseRanges.filter { $0.verseNumber == 1 }.count == 2)
        #expect(doc.text.string.components(separatedBy: "1\u{202F}\u{2060}").count == 2)
        let pages = try BiblePaginator.paginate(doc, size: .init(width: 300, height: 160))
        let visible = pages.flatMap { $0.fragments(in: doc) }.map(\.text).joined()
        #expect(visible == "First line\nSecond lineContinuation.")
        #expect(doc.verseRanges.last?.verseOffset == "First line\nSecond line".utf16.count)
    }

    @Test("too short or narrow a viewport returns an explicit failure without consuming text")
    func insufficientSpace() {
        let doc = document([.prose([.init(number: 1, text: "Word")])])
        #expect(throws: BiblePaginationError.viewportTooSmall) {
            try BiblePaginator.paginate(doc, size: .init(width: 200, height: 1))
        }
        #expect(throws: BiblePaginationError.viewportTooSmall) {
            try BiblePaginator.paginate(doc, size: .init(width: 0, height: 500))
        }
    }

    @Test("over-wide words consume character clusters without clipping horizontally")
    func longWord() throws {
        let doc = document([.prose([.init(number: 1, text: String(repeating: "abcdefghijklmnop", count: 20))])])
        let pages = try BiblePaginator.paginate(doc, size: .init(width: 120, height: 150))
        #expect(pages.count > 1)
        #expect(pages.flatMap(\.lines).allSatisfy { $0.frame.width <= 120.01 })
    }

    @Test("empty chapters are unavailable and chapter pagination always starts a new page")
    func emptyAndChapterBreak() throws {
        #expect(throws: BiblePaginationError.emptyChapter) {
            try BiblePaginator.paginate(document([]), size: .init(width: 350, height: 500))
        }
        let doc = document([.prose([.init(number: 1, text: "Short chapter.")])])
        let first = try BiblePaginator.paginate(doc, size: .init(width: 350, height: 500))
        let second = try BiblePaginator.paginate(doc, size: .init(width: 350, height: 500))
        #expect(first.count == 1 && second.count == 1)
        #expect(first[0].lines[0].frame.minY == second[0].lines[0].frame.minY)
    }

    @Test("Oversized leading and trailing headings retain an anchor on every page")
    func headingOnlyPageAnchors() throws {
        let doc = document([.heading(String(repeating: "A long heading ", count: 12)),
                            .prose([.init(number: 1, text: "Scripture text.")]),
                            .heading(String(repeating: "A trailing heading ", count: 12)),])
        let pages = try BiblePaginator.paginate(doc, size: .init(width: 150, height: 42))
        #expect(pages.filter { $0.fragments(in: doc).isEmpty }.count > 2)
        for page in pages {
            #expect(page.contains(page.locator, in: doc))
            let location = BibleBookLocation(current: page.locator, spreadOrigin: page.locator)
            #expect(BibleBookLocation.decode(location.encoded()) == location)
        }
        let reflowed = try BiblePaginator.paginate(doc, size: .init(width: 180, height: 80))
        for page in pages {
            #expect(reflowed.contains { $0.contains(page.locator, in: doc) })
        }
    }

    @Test("Supplementary anchors survive preceding decoration insertions and fall back when removed")
    func decorationIdentityAnchors() throws {
        let paragraphs: [BibleParagraph] = [.prose([.init(number: 1, text: "A scripture verse.")]),
                                           .poetry([.init(number: 1, text: "Its continuation.")]),]
        let note = BibleNoteTargetSpec.verseRange(bookId: "GEN", chapterNumber: 1, verseStart: 1, verseEnd: 1)
        let original = document(paragraphs, decorations: .init(notes: [1: [note]]))
        let originalTrailer = try #require(original.trailers.first)
        let anchor = original.locator(at: originalTrailer.range.location)
        #expect(original.characterIndex(for: anchor) == originalTrailer.range.location)
        let inserted = document(paragraphs, decorations: .init(annotations: [1: [.verseRange(
            bookId: "GEN", chapterNumber: 1, verseStart: 1, verseEnd: 1),],], notes: [1: [note]]))
        #expect(inserted.characterIndex(for: anchor) == inserted.trailers.last?.range.location)
        let removed = document(paragraphs)
        #expect(removed.verseRanges.contains { $0.range.contains(removed.characterIndex(for: anchor)) })
        #expect(removed.characterIndex(for: anchor) == NSMaxRange(try #require(removed.verseRanges.last).range) - 1)
    }
}
