#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Chat

@Suite("ChatHeader snapshots", .serialized)
@MainActor
struct ChatHeaderSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }
    @Test("light theme")
    func lightTheme() {
        verify(theme: .vellumLight, name: "header_light")
    }

    @Test("dark theme")
    func darkTheme() {
        verify(theme: .vellumDark, name: "header_dark")
    }

    @Test("very long title truncates")
    func longTitleTruncates() {
        let long = "An overly long conversation title that should ellipsis"
        let view = ChatHeader(title: long)
            .superTheme(.make(.vellumLight))
            .frame(width: 402)
        recordOrCompare(view: view, name: "header_long_title")
    }

    @Test("dynamic type XXL light")
    func dynamicTypeXXL() {
        let view = ChatHeader(title: "New chat")
            .superTheme(.make(.vellumLight))
            .dynamicTypeSize(.xxLarge)
            .frame(width: 402)
        recordOrCompare(view: view, name: "header_light_xxl")
    }

    // A non-default slider value detects missing scale wiring hidden by multiplication by 1.
    @Test("font scale max light")
    func fontScaleMax() {
        let view = ChatHeader(title: "New chat")
            .superTheme(.make(.vellumLight))
            .chatAppearance(ChatAppearance(fontScale: 1.20))
            .superTypography(.make(.serif, fontScale: 1.20))
            .frame(width: 402)
        recordOrCompare(view: view, name: "header_font_scale_max_light")
    }

    @Test("font scale max dark")
    func fontScaleMaxDark() {
        let view = ChatHeader(title: "New chat")
            .superTheme(.make(.vellumDark))
            .chatAppearance(ChatAppearance(fontScale: 1.20))
            .superTypography(.make(.serif, fontScale: 1.20))
            .frame(width: 402)
        recordOrCompare(view: view, name: "header_font_scale_max_dark")
    }

    // Combined slider and Dynamic Type scaling exercises header-height and centering limits.
    @Test("font scale max at dynamic type XXL")
    func fontScaleMaxXXL() {
        let view = ChatHeader(title: "New chat")
            .superTheme(.make(.vellumLight))
            .chatAppearance(ChatAppearance(fontScale: 1.20))
            .superTypography(.make(.serif, fontScale: 1.20))
            .dynamicTypeSize(.xxLarge)
            .frame(width: 402)
        recordOrCompare(view: view, name: "header_font_scale_max_light_xxl")
    }

    private func verify(
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let view = ChatHeader(title: "New chat")
            .superTheme(.make(theme))
            .frame(width: 402)
        recordOrCompare(view: view, name: name, function: function)
    }

    private func recordOrCompare<V: View>(
        view: V,
        name: String,
        function: String = #function
    ) {
        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .sizeThatFits),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
