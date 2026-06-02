#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Snapshot matrix for `UserBubble` carrying verse-reference pills — the
/// sent-message form of the feature. Covers text + a pill, text + multiple
/// pills, the pills-only message (empty text), across themes and at
/// Dynamic Type XXL.
@Suite("UserBubble verse-pill snapshots")
@MainActor
struct UserBubbleSnapshotTests {
    /// Register Core's bundled brand fonts before any render so this suite
    /// is order-independent in the shared test process (the xctest host never
    /// runs the app's font registration). See SnapshotFontRegistration.
    init() { SnapshotFontRegistration.ensureRegistered() }
    private func pill(_ id: String, _ label: String) -> VerseReferencePillModel {
        VerseReferencePillModel(id: id, label: label)
    }

    private func host(
        text: String,
        references: [VerseReferencePillModel],
        theme: SuperTheme.Identifier
    ) -> some View {
        UserBubble(text: text, references: references)
            .padding(.horizontal, 12)
            .frame(width: 402)
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

    @Test("text with one verse pill — light")
    func textWithPillLight() {
        recordOrCompare(
            view: host(
                text: "What does this teach about love?",
                references: [pill("r1", "John 3:16 (WEB)")],
                theme: .light
            ),
            name: "userbubble_pill_light"
        )
    }

    @Test("text with one verse pill — dark")
    func textWithPillDark() {
        recordOrCompare(
            view: host(
                text: "What does this teach about love?",
                references: [pill("r1", "John 3:16 (WEB)")],
                theme: .dark
            ),
            name: "userbubble_pill_dark"
        )
    }

    @Test("text with one verse pill — sepia")
    func textWithPillSepia() {
        recordOrCompare(
            view: host(
                text: "What does this teach about love?",
                references: [pill("r1", "John 3:16 (WEB)")],
                theme: .sepia
            ),
            name: "userbubble_pill_sepia"
        )
    }

    @Test("text with multiple verse pills — light")
    func textWithMultiplePillsLight() {
        recordOrCompare(
            view: host(
                text: "Compare these two passages.",
                references: [pill("r1", "John 3:16 (WEB)"), pill("r2", "Romans 8:28 (WEB)")],
                theme: .light
            ),
            name: "userbubble_multiple_pills_light"
        )
    }

    @Test("pills-only message with empty text — light")
    func pillsOnlyLight() {
        recordOrCompare(
            view: host(
                text: "",
                references: [pill("r1", "John 3:16-17 (WEB)")],
                theme: .light
            ),
            name: "userbubble_pills_only_light"
        )
    }

    @Test("text with one verse pill at Dynamic Type XXL")
    func textWithPillXXL() {
        recordOrCompare(
            view: host(
                text: "What does this teach about love?",
                references: [pill("r1", "John 3:16 (WEB)")],
                theme: .light
            )
            .dynamicTypeSize(.xxLarge),
            name: "userbubble_pill_light_xxl"
        )
    }
}
#endif
