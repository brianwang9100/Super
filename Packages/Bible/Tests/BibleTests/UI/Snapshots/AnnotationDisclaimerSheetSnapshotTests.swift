#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `AnnotationDisclaimerSheet` — the first-run liability
/// modal across the three themes plus a Dynamic Type XXL pass to
/// confirm the body paragraphs don't truncate at larger sizes.
@Suite("AnnotationDisclaimerSheet snapshots")
@MainActor
struct AnnotationDisclaimerSheetSnapshotTests {
    /// Register Core's bundled brand fonts so the migrated JetBrains Mono /
    /// Instrument Serif chrome faces resolve instead of baking the system
    /// fallback, and so this suite stays order-independent (registration is
    /// process-global; see `SnapshotFontRegistration`).
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("disclaimer renders in the light theme")
    func light() {
        verify(theme: .light, name: "light")
    }

    @Test("disclaimer renders in the dark theme")
    func dark() {
        verify(theme: .dark, name: "dark")
    }

    @Test("disclaimer renders in the sepia theme")
    func sepia() {
        verify(theme: .sepia, name: "sepia")
    }

    @Test("disclaimer renders at Dynamic Type XXL")
    func lightXXL() {
        verify(theme: .light, dynamicType: .xxLarge, height: 480, name: "light_xxl")
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

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: height)),
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
