#if canImport(UIKit)
import Core
import GRDBQuery
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `BibleChapterReader` driven directly. Two scenarios:
///
/// - The **generating** annotation-bubble state — the dotted bubble beside the
///   title while a `bible.annotate` dispatch is in flight.
///   `BibleScreenSnapshotTests` covers the empty (no status) and filled
///   (seeded rows) title states, but its screens all pass `nil` for
///   `chapterDispatchStatus`, so the generating branch needs its own driver.
/// - The **co-trailing** cluster — a verse carrying both an annotation bubble
///   and a note glyph, plus the chapter title carrying a filled annotation
///   bubble and a filled note glyph. This locks PR3's stable
///   annotation-then-note order in the live reader flow, the contract
///   `VerseTrailersSnapshotTests` exercises in isolation.
///
/// Rendered across light / dark / sepia because the outlined glyph strokes in
/// `theme.inkFaint`.
@Suite("BibleChapterReader snapshots")
@MainActor
struct BibleChapterReaderSnapshotTests {
    /// Register Core's bundled brand fonts before any render so the chapter
    /// title's brand serif resolves instead of baking the system fallback —
    /// and so this suite is order-independent (font registration is
    /// process-global; see `SnapshotFontRegistration`).
    init() { SnapshotFontRegistration.ensureRegistered() }

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

    @Test("annotation and note glyphs co-trail a verse and the title, light")
    func coTrailingLight() throws {
        try verifyCoTrailing(theme: .light, name: "co_trailing_light")
    }

    @Test("annotation and note glyphs co-trail a verse and the title, dark")
    func coTrailingDark() throws {
        try verifyCoTrailing(theme: .dark, name: "co_trailing_dark")
    }

    @Test("annotation and note glyphs co-trail a verse and the title, sepia")
    func coTrailingSepia() throws {
        try verifyCoTrailing(theme: .sepia, name: "co_trailing_sepia")
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
                onClearSelection: {},
                onAnnotationBubbleTap: { _ in },
                onRequestChapterAnnotation: { _ in },
                chapterDispatchStatus: .running(requestId: "gen")
            )
        }
        .frame(width: 402, height: 760)
        .superTheme(theme)
        .superTypography(.make(.serif))
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

    /// Render 1 Peter 2 with verse 1 (visible at the top of the fixed frame)
    /// carrying both an annotation and a note, and the chapter carrying a
    /// chapter-level annotation and note, so both the title and the verse show
    /// the annotation-then-note cluster within the snapshot. Seeds the
    /// in-memory DB directly via `PersistableRecord` so both `@Query`s
    /// (annotations + notes) surface their rows.
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
                verseStart: 1, verseEnd: 1, category: .summary, title: "Putting away",
                body: "A turn from malice.", source: .user, modelId: "AFM", createdAt: t0
            ).insert(db)
            try BibleAnnotationRecord(
                id: "ann-chap", target: .chapter, bookId: "1PE", chapterNumber: 2,
                category: .summary, title: "Living stones", body: "The chapter's arc.",
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
                onClearSelection: {},
                onAnnotationBubbleTap: { _ in },
                onRequestChapterAnnotation: { _ in },
                onNoteGlyphTap: { _ in }
            )
        }
        .frame(width: 402, height: 760)
        .superTheme(theme)
        .superTypography(.make(.serif))
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
