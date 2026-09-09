#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
import VisualTestSupport
@testable import Bible

/// Modal chapter content only; native sheet stacking and readiness use simulator QA.
@Suite("Bible chapter preview snapshots", .serialized)
@MainActor
struct BibleChapterPreviewSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("chapter preview header and selection render in light")
    func previewLight() {
        verify(theme: .vellumLight, name: "preview_light")
    }

    @Test("chapter preview header and selection render in dark")
    func previewDark() {
        verify(theme: .vellumDark, name: "preview_dark")
    }

    @Test("chapter preview reflows at XXL and maximum app font scale")
    func previewXXLMaxScale() {
        verify(theme: .vellumLight, dynamicType: .xxLarge, fontScale: 1.2, name: "preview_xxl_max_scale")
    }

    private func verify(
        theme: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        fontScale: CGFloat = 1,
        name: String,
        function: String = #function
    ) {
        let fullReader = BibleScreenViewModel(textLoader: DatabaseBibleTextLoader())
        let reader = fullReader.makePreviewReader(for: BibleDeepLink(bookId: "1PE", chapter: 2, verseStart: 1, verseEnd: 3))
        let preview = BibleChapterPreviewViewModel(reader: reader, onFinish: { _ in })
        let view = BibleChapterPreviewSheet(viewModel: preview)
            .superTheme(.make(theme))
            .superTypography(.make(.serif, fontScale: fontScale))
            .dynamicTypeSize(dynamicType)
            .frame(width: 402, height: 760)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 760)),
            named: name,
            testName: function
        )
        if let failure { Issue.record("\(name): \(failure)") }
    }
}
#endif
