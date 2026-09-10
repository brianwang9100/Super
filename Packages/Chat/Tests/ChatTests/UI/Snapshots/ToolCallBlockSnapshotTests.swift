#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Chat

// Native search uses SearchConfirmationRow; this fixture exercises generic approval chrome.
@Suite("ToolCallBlock snapshots", .serialized)
@MainActor
struct ToolCallBlockSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    private func awaitingCall() -> MessageList.ToolCallItem {
        MessageList.ToolCallItem(
            id: "tc-1",
            toolName: "home.unlockDoor",
            toolDisplayName: "home.unlockDoor",
            parametersJSON: #"{"door":"front"}"#,
            resultText: nil,
            status: .awaitingConfirmation
        )
    }

    private func renamedCall() -> MessageList.ToolCallItem {
        MessageList.ToolCallItem(
            id: "tc-2",
            toolName: "home.unlockDoor",
            toolDisplayName: "Unlock door",
            parametersJSON: #"{"door":"front"}"#,
            resultText: nil,
            status: .success
        )
    }

    @Test("awaiting confirmation badge, light")
    func awaitingLight() {
        verify(call: awaitingCall(), theme: .vellumLight, name: "toolcall_awaiting_light")
    }

    @Test("awaiting confirmation badge, dark")
    func awaitingDark() {
        verify(call: awaitingCall(), theme: .vellumDark, name: "toolcall_awaiting_dark")
    }

    @Test("friendly display name surfaces the FUNCTION detail, light")
    func functionDetailLight() {
        verify(call: renamedCall(), theme: .vellumLight, name: "toolcall_function_detail_light", height: 180)
    }

    @Test("friendly display name surfaces the FUNCTION detail, dark")
    func functionDetailDark() {
        verify(call: renamedCall(), theme: .vellumDark, name: "toolcall_function_detail_dark", height: 180)
    }

    @Test("dynamic type XXL on the FUNCTION detail card")
    func functionDetailXXL() {
        verify(
            call: renamedCall(), theme: .vellumLight, name: "toolcall_function_detail_light_xxl",
            height: 300, dynamicType: .xxLarge
        )
    }

    private func verify(
        call: MessageList.ToolCallItem,
        theme: SuperTheme.Identifier,
        name: String,
        height: CGFloat = 140,
        dynamicType: DynamicTypeSize = .large,
        function: String = #function
    ) {
        let view = ToolCallBlock(call: call, verbosity: .verbose)
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
