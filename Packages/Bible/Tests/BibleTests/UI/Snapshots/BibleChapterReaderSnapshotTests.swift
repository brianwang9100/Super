#if canImport(UIKit)
import Core
import GRDBQuery
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Bible

/// Covers generating/title, co-trailing, bookmarked, and chapter-end layouts missing
/// from the full-screen captures. ThemeGallerySnapshotTests owns the wider palette.
@Suite("BibleChapterReader snapshots", .serialized)
@MainActor
struct BibleChapterReaderSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("the chapter title shows the generating bubble in the light theme")
    func chapterGeneratingLight() throws {
        try verify(theme: .vellumLight, name: "chapter_generating_light")
    }

    @Test("the chapter title shows the generating bubble in the dark theme")
    func chapterGeneratingDark() throws {
        try verify(theme: .vellumDark, name: "chapter_generating_dark")
    }

    @Test("annotation and note glyphs co-trail a verse and the title, light")
    func coTrailingLight() throws {
        try verifyCoTrailing(theme: .vellumLight, name: "co_trailing_light")
    }

    @Test("annotation and note glyphs co-trail a verse and the title, dark")
    func coTrailingDark() throws {
        try verifyCoTrailing(theme: .vellumDark, name: "co_trailing_dark")
    }

    @Test("the title's bookmark glyph fills with the chapter's ribbon, light")
    func bookmarkedTitleLight() throws {
        try verifyBookmarked(theme: .vellumLight, name: "bookmarked_title_light")
    }

    @Test("the title's bookmark glyph fills with the chapter's ribbon, dark")
    func bookmarkedTitleDark() throws {
        try verifyBookmarked(theme: .vellumDark, name: "bookmarked_title_dark")
    }

    @Test("chapter-end navigation clears the floating controls",
          arguments: [SuperTheme.Identifier.vellumLight, .vellumDark])
    func chapterEnd(theme: SuperTheme.Identifier) throws {
        try verifyChapterEnd(theme: theme, name: "chapter_end_\(theme.rawValue)")
    }

    @Test("chapter-end clearance remains available at XXL",
          arguments: [SuperTheme.Identifier.vellumLight, .vellumDark])
    func chapterEndXXL(theme: SuperTheme.Identifier) throws {
        try verifyChapterEnd(theme: theme, name: "chapter_end_\(theme.rawValue)_xxl", dynamicType: .xxLarge)
    }

    private func verifyChapterEnd(
        theme themeID: SuperTheme.Identifier,
        name: String,
        dynamicType: DynamicTypeSize = .large,
        function: String = #function
    ) throws {
        let database = try BibleDatabase.makeInMemory()
        let chapter = try #require(
            try DatabaseBibleTextLoader().loadChapter(bookId: "1PE", chapterNumber: 2, translation: .web)
        )
        let theme = SuperTheme.make(themeID)
        let view = BibleChapterReader(
            chapter: chapter,
            bookId: "1PE",
            bookName: "1 Peter",
            selectedVerses: [25],
            previousLabel: "1 Peter 1",
            nextLabel: "1 Peter 3",
            onTapVerse: { _ in },
            onPrevious: {},
            onNext: {},
            onBackgroundTap: {}
        )
        .defaultScrollAnchor(.bottom)
        .frame(width: 402, height: 760)
        .background(theme.background)
        .superTheme(theme)
        .superTypography(.make(.serif))
        .dynamicTypeSize(dynamicType)
        .databaseContext(.readOnly { database.queue })

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 760)),
            named: name,
            testName: function
        )
        if let failure { Issue.record("\(name): \(failure)") }
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) throws {
        let database = try BibleDatabase.makeInMemory()
        let chapter = try #require(
            try DatabaseBibleTextLoader().loadChapter(bookId: "1PE", chapterNumber: 2, translation: .web)
        )
        let theme = SuperTheme.make(themeID)
        let view = ZStack {
            theme.background
            BibleChapterReader(
                chapter: chapter,
                bookId: "1PE",
                bookName: "1 Peter",
                selectedVerses: [],
                previousLabel: "1 Peter 1",
                nextLabel: "1 Peter 3",
                onTapVerse: { _ in },
                onPrevious: {},
                onNext: {},
                onBackgroundTap: {},
                onAnnotationBubbleTap: { _ in },
                onRequestChapterAnnotation: { _ in },
                chapterDispatchStatus: .running(requestId: "gen")
            )
        }
        .frame(width: 402, height: 760)
        .superTheme(theme)
        .superTypography(.make(.serif))
        .databaseContext(.readOnly { database.queue })

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 760)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }

    // Put annotation/note pairs on visible verse 1 and the chapter title to cover both clusters.
    private func verifyCoTrailing(
        theme themeID: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let database = try BibleDatabase.makeInMemory()
        try database.queue.write { db in
            try BibleAnnotationRecord(
                id: "ann-v1", target: .verse, bookId: "1PE", chapterNumber: 2,
                verseStart: 1, verseEnd: 1, summary: "Putting away — A turn from malice.", source: .user, modelId: "AFM", createdAt: t0
            ).insert(db)
            try BibleAnnotationRecord(
                id: "ann-chap", target: .chapter, bookId: "1PE", chapterNumber: 2,
                summary: "Living stones — The chapter's arc.",
                source: .user, modelId: "AFM", createdAt: t0
            ).insert(db)
            try BibleNoteRecord(
                id: "note-v1", target: .verse, bookId: "1PE", chapterNumber: 2,
                verseStart: 1, verseEnd: 1, body: "Come back to this one.",
                source: .user, createdAt: t0, updatedAt: t0
            ).insert(db)
            try BibleNoteRecord(
                id: "note-chap", target: .chapter, bookId: "1PE", chapterNumber: 2,
                body: "Whole-chapter thought.", source: .user, createdAt: t0, updatedAt: t0
            ).insert(db)
        }
        let chapter = try #require(
            try DatabaseBibleTextLoader().loadChapter(bookId: "1PE", chapterNumber: 2, translation: .web)
        )
        let theme = SuperTheme.make(themeID)
        let view = ZStack {
            theme.background
            BibleChapterReader(
                chapter: chapter,
                bookId: "1PE",
                bookName: "1 Peter",
                selectedVerses: [],
                previousLabel: "1 Peter 1",
                nextLabel: "1 Peter 3",
                onTapVerse: { _ in },
                onPrevious: {},
                onNext: {},
                onBackgroundTap: {},
                onAnnotationBubbleTap: { _ in },
                onRequestChapterAnnotation: { _ in },
                onNoteGlyphTap: { _ in }
            )
        }
        .frame(width: 402, height: 760)
        .superTheme(theme)
        .superTypography(.make(.serif))
        .databaseContext(.readOnly { database.queue })

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 760)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }

    private func verifyBookmarked(
        theme themeID: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let database = try BibleDatabase.makeInMemory()
        try database.queue.write { db in
            try BibleBookmarkRecord(
                id: "bm-clay", colorId: "clay", bookId: "1PE", chapterNumber: 2,
                createdAt: t0
            ).insert(db)
        }
        let chapter = try #require(
            try DatabaseBibleTextLoader().loadChapter(bookId: "1PE", chapterNumber: 2, translation: .web)
        )
        let theme = SuperTheme.make(themeID)
        let view = ZStack {
            theme.background
            BibleChapterReader(
                chapter: chapter,
                bookId: "1PE",
                bookName: "1 Peter",
                selectedVerses: [],
                previousLabel: "1 Peter 1",
                nextLabel: "1 Peter 3",
                onTapVerse: { _ in },
                onPrevious: {},
                onNext: {},
                onBackgroundTap: {},
                onAnnotationBubbleTap: { _ in },
                onRequestChapterAnnotation: { _ in },
                onNoteGlyphTap: { _ in },
                onBookmarkTap: {}
            )
        }
        .frame(width: 402, height: 760)
        .superTheme(theme)
        .superTypography(.make(.serif))
        .databaseContext(.readOnly { database.queue })

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 760)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
