#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Snapshot matrix for `VerseReferencePill` — the verse-reference chip
/// shown in the composer strip and (read-only) inside a sent user bubble.
/// Covers light/dark/sepia, the removable vs. read-only forms, label
/// truncation, and Dynamic Type XXL.
@Suite("VerseReferencePill snapshots")
@MainActor
struct VerseReferencePillSnapshotTests {
    private func host<V: View>(_ view: V, theme: SuperTheme.Identifier) -> some View {
        view
            .padding(12)
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

    @Test("removable pill — light")
    func removableLight() {
        recordOrCompare(
            view: host(VerseReferencePill(label: "John 3:16-17 (WEB)", onRemove: {}), theme: .light),
            name: "pill_removable_light"
        )
    }

    @Test("removable pill — dark")
    func removableDark() {
        recordOrCompare(
            view: host(VerseReferencePill(label: "John 3:16-17 (WEB)", onRemove: {}), theme: .dark),
            name: "pill_removable_dark"
        )
    }

    @Test("removable pill — sepia")
    func removableSepia() {
        recordOrCompare(
            view: host(VerseReferencePill(label: "John 3:16-17 (WEB)", onRemove: {}), theme: .sepia),
            name: "pill_removable_sepia"
        )
    }

    @Test("read-only pill (no remove control) — light")
    func readOnlyLight() {
        recordOrCompare(
            view: host(VerseReferencePill(label: "John 3:16-17 (WEB)", onRemove: nil), theme: .light),
            name: "pill_readonly_light"
        )
    }

    @Test("long label truncates within a constrained width")
    func longLabelTruncates() {
        recordOrCompare(
            view: host(
                VerseReferencePill(label: "1 Corinthians 13:1-13 (WEB)", onRemove: {})
                    .frame(width: 160, alignment: .leading),
                theme: .light
            ),
            name: "pill_long_label_truncated_light"
        )
    }

    @Test("removable pill at Dynamic Type XXL")
    func removableXXL() {
        recordOrCompare(
            view: host(VerseReferencePill(label: "John 3:16-17 (WEB)", onRemove: {}), theme: .light)
                .dynamicTypeSize(.xxLarge),
            name: "pill_removable_light_xxl"
        )
    }
}
#endif
