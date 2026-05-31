#if canImport(UIKit)
import Core
import GRDBQuery
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `BibleChapterReader` driven directly, to lock the in-context
/// chapter-title layout for the **generating** annotation-bubble state — the
/// dotted bubble beside the title while a `bible.annotate` dispatch is in
/// flight. `BibleScreenSnapshotTests` covers the empty (no status) and filled
/// (seeded rows) title states, but its screens all pass `nil` for
/// `chapterDispatchStatus`, so the generating branch needs its own driver.
/// Rendered across light / dark / sepia because the outlined glyph strokes in
/// `theme.inkFaint`.
@Suite("BibleChapterReader snapshots")
@MainActor
struct BibleChapterReaderSnapshotTests {
    @Test("the chapter title shows the generating bubble in the light theme")
    func chapterGeneratingLight() throws {
        try verify(theme: .light, name: "chapter_generating_light")
    }

    @Test("the chapter title shows the generating bubble in the dark theme")
    func chapterGeneratingDark() throws {
        try verify(theme: .dark, name: "chapter_generating_dark")
    }

    @Test("the chapter title shows the generating bubble in the sepia theme")
    func chapterGeneratingSepia() throws {
        try verify(theme: .sepia, name: "chapter_generating_sepia")
    }

    /// Render 1 Peter 2 with an empty annotation database (so the chapter
    /// bubble isn't filled) and a `.running` dispatch status, which flips the
    /// title bubble to its generating glyph. The empty in-memory
    /// `DatabaseContext` satisfies the reader's `@Query` requests.
    private func verify(
        theme themeID: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) throws {
        let database = try BibleDatabase.makeInMemory()
        let book = try BundledBibleTextLoader().loadBook(id: "1PE", translation: .defaultTranslation)
        let chapter = try #require(book.chapter(2))
        let theme = SuperTheme.make(themeID)
        let view = ZStack {
            theme.background
            BibleChapterReader(
                chapter: chapter,
                bookId: "1PE",
                bookName: book.name,
                selectedVerses: [],
                previousLabel: "1 Peter 1",
                nextLabel: "1 Peter 3",
                onTapVerse: { _ in },
                onPrevious: {},
                onNext: {},
                onClearSelection: {},
                onAnnotationBubbleTap: { _ in },
                onRequestChapterAnnotation: { _ in },
                chapterDispatchStatus: .running(requestId: "gen")
            )
        }
        .frame(width: 402, height: 760)
        .superTheme(theme)
        .databaseContext(.readOnly { database.queue })

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 760)),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
