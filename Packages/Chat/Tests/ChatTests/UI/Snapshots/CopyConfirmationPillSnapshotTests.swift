#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Snapshot baselines for ``CopyConfirmationPill`` — the transient
/// "Copied!" pill that floats above the composer after the user taps
/// Copy on an assistant message. Covers light/dark/sepia plus a
/// Dynamic Type XXL variant.
@Suite("CopyConfirmationPill snapshots")
@MainActor
struct CopyConfirmationPillSnapshotTests {
    private func host<V: View>(_ view: V, theme: SuperTheme.Identifier) -> some View {
        view
            .padding(16)
            .background(SuperTheme.make(theme).background)
            .superTheme(.make(theme))
    }

    private func recordOrCompare<V: View>(view: V, name: String, function: String = #function) {
        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .sizeThatFits),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure { Issue.record("\(name): \(failure)") }
    }

    @Test("pill — light")
    func pillLight() {
        recordOrCompare(
            view: host(CopyConfirmationPill(), theme: .light),
            name: "copy_pill_light"
        )
    }

    @Test("pill — dark")
    func pillDark() {
        recordOrCompare(
            view: host(CopyConfirmationPill(), theme: .dark),
            name: "copy_pill_dark"
        )
    }

    @Test("pill — sepia")
    func pillSepia() {
        recordOrCompare(
            view: host(CopyConfirmationPill(), theme: .sepia),
            name: "copy_pill_sepia"
        )
    }

    @Test("pill at Dynamic Type XXL")
    func pillXXL() {
        recordOrCompare(
            view: host(CopyConfirmationPill(), theme: .light)
                .dynamicTypeSize(.xxLarge),
            name: "copy_pill_light_xxl"
        )
    }
}
#endif
