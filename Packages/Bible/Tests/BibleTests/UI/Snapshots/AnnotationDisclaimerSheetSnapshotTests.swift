#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Bible

@Suite("AnnotationDisclaimerSheet snapshots", .serialized)
@MainActor
struct AnnotationDisclaimerSheetSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("disclaimer renders in the light theme")
    func light() {
        verify(theme: .vellumLight, name: "light")
    }

    @Test("disclaimer renders in the dark theme")
    func dark() {
        verify(theme: .vellumDark, name: "dark")
    }

    @Test("disclaimer renders at Dynamic Type XXL")
    func lightXXL() {
        verify(theme: .vellumLight, dynamicType: .xxLarge, height: 480, name: "light_xxl")
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        height: CGFloat = 380,
        name: String,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        let view = ZStack(alignment: .bottom) {
            theme.background
            AnnotationDisclaimerSheet(onGotIt: {}, bottomInset: 0)
        }
        .frame(width: 393, height: height)
        .superTheme(theme)
        .dynamicTypeSize(dynamicType)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: height)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
