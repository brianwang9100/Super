#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Chat

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

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: height)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
