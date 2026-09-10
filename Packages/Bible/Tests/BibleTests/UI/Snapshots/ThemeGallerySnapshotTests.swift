#if canImport(UIKit)
import Core
import GRDBQuery
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Bible

/// Owns all eight reader theme variants so screen suites need only the default light/dark pair.
@Suite("Theme gallery — Bible reader", .serialized)
@MainActor
struct ThemeGallerySnapshotTests {
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
                navigation: BibleChapterNavigation(
                    previousLabel: "1 Peter 1",
                    nextLabel: "1 Peter 3",
                    onPrevious: {}, onNext: {}
                ),
                onTapVerse: { _ in },
                onBackgroundTap: {},
                onAnnotationBubbleTap: { _ in },
                onRequestChapterAnnotation: { _ in },
                chapterDispatchStatus: nil
            )
        }
        .frame(width: 402, height: 760)
        .superTheme(theme)
        .superTypography(.make(.serif))
        .databaseContext(.readOnly { database.queue })

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 760)),
            named: "gallery_reader_\(id.rawValue)",
            testName: #function
        )
        if let failure {
            Issue.record("gallery_reader_\(id.rawValue): \(failure)")
        }
    }
}
#endif
