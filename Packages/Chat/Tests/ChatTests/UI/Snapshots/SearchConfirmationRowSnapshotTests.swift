#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Chat

@Suite("SearchConfirmationRow snapshots", .serialized)
@MainActor
struct SearchConfirmationRowSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    private func call(status: MessageList.ToolCallItem.Status) -> MessageList.ToolCallItem {
        MessageList.ToolCallItem(
            id: "tc-search",
            toolName: NativeWebSearch.proposalToolName,
            toolDisplayName: NativeWebSearch.proposalToolName,
            parametersJSON: #"{"query":"latest mars rover findings","reason":"This is about current events beyond my training knowledge."}"#,
            resultText: nil,
            status: status
        )
    }

    @Test("awaiting, light")
    func awaitingLight() {
        verify(status: .awaitingConfirmation, theme: .vellumLight, height: 200, name: "search_confirm_awaiting_light")
    }

    @Test("awaiting, dark")
    func awaitingDark() {
        verify(status: .awaitingConfirmation, theme: .vellumDark, height: 200, name: "search_confirm_awaiting_dark")
    }

    @Test("awaiting, dynamic type XXL")
    func awaitingXXL() {
        verify(
            status: .awaitingConfirmation, theme: .vellumLight, dynamicType: .xxLarge, height: 320,
            name: "search_confirm_awaiting_light_xxl"
        )
    }

    // Approved search renders on the answer turn through WebSearchCallCell;
    // only the skipped summary remains in this row.

    @Test("resolved skipped, light")
    func skippedLight() {
        verify(status: .failed, theme: .vellumLight, height: 80, name: "search_confirm_skipped_light")
    }

    @Test("resolved skipped, dark")
    func skippedDark() {
        verify(status: .failed, theme: .vellumDark, height: 80, name: "search_confirm_skipped_dark")
    }

    @Test("resolved skipped, dynamic type XXL")
    func skippedXXL() {
        verify(
            status: .failed, theme: .vellumLight, dynamicType: .xxLarge, height: 140,
            name: "search_confirm_skipped_light_xxl"
        )
    }

    private func verify(
        status: MessageList.ToolCallItem.Status,
        theme: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        height: CGFloat,
        name: String,
        function: String = #function
    ) {
        let view = SearchConfirmationRow(call: call(status: status))
            .superTheme(.make(theme))
            .dynamicTypeSize(dynamicType)
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
            .frame(width: 402, height: height)

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
