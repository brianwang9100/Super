#if canImport(UIKit)
import Core
import GRDBQuery
import SnapshotTesting
import SwiftUI
import Testing
import VisualTestSupport
@testable import Bible

@Suite("Bible reading modes snapshots", .serialized)
@MainActor
struct BibleReadingModesSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test func bookContinuationLight() async throws {
        try await bookContinuation(theme: .vellumLight, name: "book_continuation_light")
    }

    @Test func bookContinuationDark() async throws {
        try await bookContinuation(theme: .vellumDark, name: "book_continuation_dark")
    }

    @Test func compactChapterOpening() async throws {
        let size = CGSize(width: 402, height: 660)
        let pageSize = CGSize(width: 354, height: 540)
        let workspace = await makeWorkspace(loader: BookLoader(), pageSize: pageSize, pageCount: 1)
        workspace.reader.selectChapter(bookId: "GEN", chapterNumber: 2)
        workspace.explicitNavigationChanged()
        await workspace._waitForPendingPagination()
        let page = try #require(workspace.visiblePages.first)
        #expect(workspace.visiblePages.count == 1)
        #expect(page.position.chapterNumber == 2)
        #expect(page.locator.utf16Offset == 0)
        try verifySpread(workspace, pageSize: pageSize, size: size,
                         theme: .vellumLight, name: "compact_chapter_opening")
    }

    @Test func comparisonAlignedRows() async throws {
        try await comparison(stacked: false, size: CGSize(width: 1000, height: 900),
                             fontScale: 1, name: "comparison_aligned_rows")
    }

    @Test func comparisonStackedFontScaleMax() async throws {
        try await comparison(stacked: true, size: CGSize(width: 540, height: 1100),
                             fontScale: 1.2, name: "comparison_stacked_font_scale_max")
    }

    @Test func inlineControlsRegular() {
        controls(size: CGSize(width: 1000, height: 480), name: "inline_controls_regular")
    }

    @Test func inlineControlsNarrowXXL() {
        controls(size: CGSize(width: 540, height: 620), dynamicType: .xxLarge,
                 fontScale: 1.2, name: "inline_controls_narrow_xxl")
    }

    private func bookContinuation(theme: SuperTheme.Identifier, name: String,
                                  function: String = #function) async throws {
        let pageSize = CGSize(width: 426, height: 510)
        let workspace = await makeWorkspace(loader: BookLoader(), pageSize: pageSize, pageCount: 2)
        let pages = workspace.visiblePages
        #expect(pages.count == 2)
        let continuation = try #require(pages.last)
        #expect(continuation.position.chapterNumber == 1)
        #expect(continuation.locator.verseNumber == 1)
        #expect(continuation.locator.utf16Offset > 0)
        try verifySpread(workspace, pageSize: pageSize, size: CGSize(width: 924, height: 630),
                         theme: theme, name: name, function: function)
    }

    private func verifySpread(_ workspace: BibleReadingWorkspaceViewModel, pageSize: CGSize,
                              size: CGSize, theme: SuperTheme.Identifier, name: String,
                              function: String = #function) throws {
        let database = try BibleDatabase.makeInMemory()
        let view = BibleBookSpread(workspace: workspace, pageSize: pageSize,
                                   onAnnotation: { _, _ in }, onNote: { _ in })
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .databaseContext(.readOnly { database.queue })
        verify(view, size: size, theme: theme, name: name, function: function)
    }

    private func comparison(stacked: Bool, size: CGSize, fontScale: CGFloat, name: String,
                            function: String = #function) async throws {
        let workspace = await makeWorkspace(loader: ComparisonLoader(), pageSize: CGSize(width: 400, height: 600), pageCount: 1)
        workspace.selectMode(.compare)
        let primary = try #require(workspace.reader.primarySource)
        let secondary = try #require(workspace.comparisonSource)
        let rows = BibleComparisonAssembler.assemble(primary: primary.chapter, secondary: secondary.chapter).rows
        #expect(rows.map(\.verseNumber) == [1, 2, 3])
        #expect(rows[1].secondary == nil)
        #expect(rows[0].primary?.headings == ["A song of trust"])
        #expect(rows[0].primary?.text.contains("\n") == true)
        let database = try BibleDatabase.makeInMemory()
        let view = BibleTranslationComparison(workspace: workspace, stacked: stacked, topInset: 0)
            .databaseContext(.readOnly { database.queue })
        verify(view, size: size, fontScale: fontScale, name: name, function: function)
    }

    private func controls(size: CGSize, dynamicType: DynamicTypeSize = .large, fontScale: CGFloat = 1,
                          name: String, function: String = #function) {
        let controller = NarrationController(service: FakeNarrationService())
        controller.start(utterances: [.init(verseNumber: 9, text: "A chosen people")])
        controller._simulateEvent(.started(verseNumber: 9))
        let view = VStack(spacing: 28) {
            BibleActionSheet(citation: "Song of Solomon 6:4–6, 9 (KJV)", shareText: "A chosen people",
                             onHighlight: { _ in }, onClearHighlight: {}, onCopy: {}, onNarrate: {},
                             onAddToChat: {}, onNewChat: {}, onAnnotate: {}, onAddNote: {}, onClose: {}, inline: true)
            NarrationTransportSheet(controller: controller, citation: "Song of Solomon 6:9 (KJV)",
                                    onStop: {}, onRestart: {}, onClose: {}, inline: true,
                                    onResumeFollowing: {})
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SuperTheme.make(.vellumLight).backgroundRaised)
        verify(view, size: size, dynamicType: dynamicType, fontScale: fontScale,
               name: name, function: function)
    }

    private func makeWorkspace(loader: any BibleTextLoader, pageSize: CGSize,
                               pageCount: Int) async -> BibleReadingWorkspaceViewModel {
        let typography = SuperTypography.make(.serif)
        let context = EnvironmentValues().fontResolutionContext
        let workspace = BibleReadingWorkspaceViewModel(reader: .init(
            textLoader: loader, clock: FixedClock(Date(timeIntervalSince1970: 1)),
            initialPosition: .init(bookId: "GEN", chapterNumber: 1), initialTranslation: .kjv))
        workspace.updateLayout(.init(size: pageSize,
                                     body: typography.reading(24, relativeTo: nil).resolve(in: context),
                                     heading: typography.reading(28, relativeTo: nil).resolve(in: context),
                                     number: typography.font(size: 13).resolve(in: context)), pageCount: pageCount)
        await workspace.load()
        await workspace._waitForPendingPagination()
        return workspace
    }

    private func verify(_ content: some View, size: CGSize, theme: SuperTheme.Identifier = .vellumLight,
                        dynamicType: DynamicTypeSize = .large, fontScale: CGFloat = 1,
                        name: String, function: String) {
        let view = content
            .frame(width: size.width, height: size.height)
            .background(SuperTheme.make(theme).background)
            .superTheme(.make(theme))
            .superTypography(.make(.serif, fontScale: fontScale))
            .dynamicTypeSize(dynamicType)
        if let failure = verifyVisualSnapshot(of: view, as: .image(layout: .fixed(width: size.width, height: size.height)),
                                               named: name, testName: function) {
            Issue.record("\(name): \(failure)")
        }
    }

    private struct BookLoader: BibleTextLoader {
        func loadChapter(bookId: String, chapterNumber: Int, translation: BibleTranslation) throws -> BibleChapter? {
            if chapterNumber == 1 {
                return .init(number: 1, paragraphs: [
                    .heading("In the beginning"),
                    .prose([.init(number: 1, text: String(repeating: "And the light shone upon the waters, and the earth was filled with life. ", count: 22))]),
                ])
            }
            return .init(number: chapterNumber, paragraphs: [
                .heading("The heavens and the earth"),
                .prose([.init(number: 1, text: "Thus the heavens and the earth were finished, and all the host of them.")]),
                .poetry([.init(number: 2, text: "The morning stars sang together,\nand all the sons of God shouted for joy.")]),
            ])
        }
    }

    private struct ComparisonLoader: BibleTextLoader {
        func loadChapter(bookId: String, chapterNumber: Int, translation: BibleTranslation) throws -> BibleChapter? {
            if translation == .kjv {
                return .init(number: chapterNumber, paragraphs: [
                    .heading("A song of trust"),
                    .poetry([.init(number: 1, text: "The LORD is my shepherd;\nI shall not want.")]),
                    .prose([.init(number: 2, text: "He maketh me to lie down in green pastures: he leadeth me beside the still waters.")]),
                    .heading("Paths of righteousness"),
                    .prose([.init(number: 3, text: "He restoreth my soul.")]),
                ])
            }
            return .init(number: chapterNumber, paragraphs: [
                .heading("The shepherd’s care"),
                .prose([.init(number: 1, text: "Yahweh is my shepherd: I shall lack nothing. He watches over me through every season and leads me safely home.")]),
                .prose([.init(number: 3, text: "He restores my soul. He guides me in the paths of righteousness for his name’s sake.")]),
            ])
        }
    }
}
#endif
