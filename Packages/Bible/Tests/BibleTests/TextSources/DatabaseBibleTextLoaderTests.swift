import Foundation
import Testing
@testable import Bible

/// Unit tests for `DatabaseBibleTextLoader` against an in-memory `chapter` table —
/// the decode path (all three paragraph shapes plus a boundary-fragmented verse),
/// the missing-book / missing-chapter → nil contract, and the unavailable-database
/// degradation.
@Suite("DatabaseBibleTextLoader")
struct DatabaseBibleTextLoaderTests {
    /// A chapter exercising every paragraph kind: a heading, prose, poetry with an
    /// embedded line break, and verse 2 fragmented across the prose/poetry boundary
    /// (two fragments sharing one number).
    private static let richChapter = BibleChapter(number: 2, paragraphs: [
        .heading("A Heading"),
        .prose([
            BibleVerse(number: 1, text: "Prose verse one."),
            BibleVerse(number: 2, text: "Prose start of two —"),
        ]),
        .poetry([
            BibleVerse(number: 2, text: "poetic line A\npoetic line B"),
            BibleVerse(number: 3, text: "Poetry verse three."),
        ]),
    ])

    private func makeLoader(_ chapters: [BibleTextDatabase.ChapterRow]) throws -> DatabaseBibleTextLoader {
        DatabaseBibleTextLoader(database: try .makeInMemory(chapters: chapters))
    }

    @Test("a stored chapter decodes back to the exact BibleChapter, all paragraph shapes intact")
    func decodesRichChapter() throws {
        let loader = try makeLoader([
            try .init(translation: .web, bookId: "1PE", number: 2, chapter: Self.richChapter),
        ])
        let loaded = try loader.loadChapter(bookId: "1PE", chapterNumber: 2, translation: .web)
        #expect(loaded == Self.richChapter)
    }

    @Test("a chapter is scoped to its translation")
    func scopedToTranslation() throws {
        let loader = try makeLoader([
            try .init(translation: .web, bookId: "1PE", number: 2, chapter: Self.richChapter),
        ])
        #expect(try loader.loadChapter(bookId: "1PE", chapterNumber: 2, translation: .web) != nil)
        #expect(try loader.loadChapter(bookId: "1PE", chapterNumber: 2, translation: .kjv) == nil)
    }

    @Test("an unknown book returns nil")
    func unknownBook() throws {
        let loader = try makeLoader([
            try .init(translation: .web, bookId: "1PE", number: 2, chapter: Self.richChapter),
        ])
        #expect(try loader.loadChapter(bookId: "GEN", chapterNumber: 1, translation: .web) == nil)
    }

    @Test("an absent chapter number returns nil")
    func absentChapter() throws {
        let loader = try makeLoader([
            try .init(translation: .web, bookId: "1PE", number: 2, chapter: Self.richChapter),
        ])
        #expect(try loader.loadChapter(bookId: "1PE", chapterNumber: 99, translation: .web) == nil)
    }

    @Test("an unavailable database returns nil rather than throwing")
    func nilDatabase() throws {
        let loader = DatabaseBibleTextLoader(database: nil)
        #expect(try loader.loadChapter(bookId: "1PE", chapterNumber: 2, translation: .web) == nil)
    }
}
