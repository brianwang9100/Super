#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Bible

@Suite("BibleActionSheet snapshots", .serialized)
@MainActor
struct BibleActionSheetSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("the action sheet renders in the light theme")
    func light() {
        verify(theme: .vellumLight, citation: "1 Peter 2:9", name: "light")
    }

    @Test("the action sheet renders in the dark theme")
    func dark() {
        verify(theme: .vellumDark, citation: "1 Peter 2:9", name: "dark")
    }

    @Test("the action sheet renders a multi-range citation")
    func multiRange() {
        verify(theme: .vellumLight, citation: "1 Peter 2:4-6, 9", name: "multi_range_light")
    }

    @Test("the action sheet renders at Dynamic Type XXL")
    func lightXXL() {
        verify(theme: .vellumLight, citation: "1 Peter 2:9", dynamicType: .xxLarge,
               name: "light_xxl")
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        citation: String,
        dynamicType: DynamicTypeSize = .large,
        name: String,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        let view = ZStack(alignment: .bottom) {
            theme.background
            BibleActionSheet(
                citation: citation,
                shareText: "…",
                onHighlight: { _ in },
                onClearHighlight: {},
                onCopy: {},
                onNarrate: {},
                onAddToChat: {},
                onNewChat: {},
                onAnnotate: {},
                onAddNote: {},
                onClose: {}
            )
        }
        .frame(width: 402, height: 330)
        .superTheme(theme)
        .dynamicTypeSize(dynamicType)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 330)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
