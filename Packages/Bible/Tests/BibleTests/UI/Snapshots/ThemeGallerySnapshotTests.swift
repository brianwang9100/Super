#if canImport(UIKit)
import Core
import GRDBQuery
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// The single place all eight theme variants (four families × light/dark) are
/// pixel-locked on the Bible reader. The per-screen reader suites render only
/// Vellum light/dark (the default) to keep CI cost flat; this gallery is where
/// Lapis / Scriptorium / Slate — and Vellum again — get their palette coverage
/// on the verse-reading surface (EB Garamond reading body, verse numbers,
/// chapter title), so a palette regression in any family fails here.
@Suite("Theme gallery — Bible reader")
@MainActor
struct ThemeGallerySnapshotTests {
    /// Register Core's bundled brand fonts before any render so the chapter
    /// title's brand serif and the EB Garamond reading body resolve instead of
    /// baking the system fallback (see SnapshotFontRegistration).
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("the reader renders in every theme variant",
          arguments: SuperTheme.Identifier.allCases)
    func gallery(_ id: SuperTheme.Identifier) throws {
        let database = try BibleDatabase.makeInMemory()
        let chapter = try #require(
            try DatabaseBibleTextLoader().loadChapter(bookId: "1PE", chapterNumber: 2, translation: .web)
        )
        let theme = SuperTheme.make(id)
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
                chapterDispatchStatus: nil
            )
        }
        .frame(width: 402, height: 760)
        .superTheme(theme)
        .superTypography(.make(.serif))
        .databaseContext(.readOnly { database.queue })

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 760)),
            named: "gallery_reader_\(id.rawValue)",
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: #function
        )
        if let failure {
            Issue.record("gallery_reader_\(id.rawValue): \(failure)")
        }
    }
}
#endif
