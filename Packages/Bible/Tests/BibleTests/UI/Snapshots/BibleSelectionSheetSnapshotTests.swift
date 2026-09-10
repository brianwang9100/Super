#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
import VisualTestSupport
@testable import Bible

@Suite("BibleSelectionSheet snapshots", .serialized)
@MainActor
struct BibleSelectionSheetSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("the book tab renders without a Read footer in light appearance")
    func bookLight() {
        verify(theme: .vellumLight, name: "book_light")
    }

    @Test("the selected glass segment and flat base remain distinct in dark appearance")
    func bookDark() {
        verify(theme: .vellumDark, name: "book_dark")
    }

    @Test("the translation tab renders without a Read footer")
    func translationLight() {
        verify(theme: .vellumLight, tab: .translation, name: "translation_light")
    }

    @Test("large type and maximum app font scale reflow the unified controls")
    func largeText() {
        verify(theme: .vellumLight, dynamicType: .xxLarge, fontScale: 1.2, name: "large_text")
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        tab: BibleSelectionSheetViewModel.Tab = .book,
        dynamicType: DynamicTypeSize = .large,
        fontScale: CGFloat = 1,
        name: String,
        function: String = #function
    ) {
        let model = BibleSelectionSheetViewModel(
            position: BiblePosition(bookId: "2CO", chapterNumber: 13), translation: .web
        )
        model.tab = tab
        let view = BibleSelectionSheet(
            viewModel: model, onSelect: {}, onSelectTranslation: { model.translation = $0 }, onClose: {},
            onPresentBookAnnotations: { _ in }, onRequestBookAnnotations: { _ in },
            onPresentBookNotes: { _ in }
        )
        .frame(width: 375, height: 640)
        .dynamicTypeSize(dynamicType)
        .superFontScale(fontScale)
        .superTypography(.make(.serif, fontScale: fontScale))
        .superTheme(.make(themeID))
        let failure = verifyVisualSnapshot(
            of: view, as: .image(layout: .fixed(width: 375, height: 640)),
            named: name, testName: function
        )
        if let failure { Issue.record("\(failure)") }
    }
}
#endif
