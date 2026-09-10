#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Chat

/// MessageList owns the animation; this pill's steady-state image is unchanged by Reduce Motion.
@Suite("CopyConfirmationPill snapshots", .serialized)
@MainActor
struct CopyConfirmationPillSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }
    private func host<V: View>(_ view: V, theme: SuperTheme.Identifier) -> some View {
        view
            .padding(16)
            .background(SuperTheme.make(theme).background)
            .superTheme(.make(theme))
    }

    private func recordOrCompare<V: View>(view: V, name: String, function: String = #function) {
        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .sizeThatFits),
            named: name,
            testName: function
        )
        if let failure { Issue.record("\(name): \(failure)") }
    }

    @Test("pill — light")
    func pillLight() {
        recordOrCompare(
            view: host(CopyConfirmationPill(), theme: .vellumLight),
            name: "copy_pill_light"
        )
    }

    @Test("pill — dark")
    func pillDark() {
        recordOrCompare(
            view: host(CopyConfirmationPill(), theme: .vellumDark),
            name: "copy_pill_dark"
        )
    }

    @Test("pill at Dynamic Type XXL")
    func pillXXL() {
        recordOrCompare(
            view: host(CopyConfirmationPill(), theme: .vellumLight)
                .dynamicTypeSize(.xxLarge),
            name: "copy_pill_light_xxl"
        )
    }
}
#endif
