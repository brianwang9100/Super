#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Snapshots for the empty-state `SuggestedActions` glass-button cluster, in
/// Vellum light and dark. Rendered over the theme background (not the host
/// white) so the glass capsules read against the real backdrop.
@Suite("SuggestedActions snapshots", .serialized)
@MainActor
struct SuggestedActionsSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    private let actions = [
        SuggestedChatAction(label: "Explain a verse", message: "Explain a Bible verse to me."),
        SuggestedChatAction(label: "Today's reading", message: "What should I read in the Bible today?"),
        SuggestedChatAction(label: "Write a prayer", message: "Write a short prayer for me."),
    ]

    @Test("light theme")
    func light() { verify(theme: .vellumLight, name: "suggested_actions_light") }

    @Test("dark theme")
    func dark() { verify(theme: .vellumDark, name: "suggested_actions_dark") }

    @Test("light theme at dynamic type XXL")
    func lightXXL() {
        // Text reflow: at XXL the labels grow and the capsules follow, so per
        // §Testing.3 this is the variant that catches button-layout breakage.
        verify(theme: .vellumLight, name: "suggested_actions_light_xxl", dynamicType: .xxLarge, height: 320)
    }

    private func verify(
        theme: SuperTheme.Identifier,
        name: String,
        dynamicType: DynamicTypeSize = .large,
        height: CGFloat = 254,
        function: String = #function
    ) {
        let resolved = SuperTheme.make(theme)
        let view = SuggestedActions(actions: actions, onSend: { _ in })
            .superTheme(resolved)
            .dynamicTypeSize(dynamicType)
            .frame(width: 402, height: height - 14, alignment: .bottomTrailing)
            .padding(.trailing, 20)
            .padding(.bottom, 14)
            .background(resolved.background)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: height)),
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
