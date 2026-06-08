#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Snapshots for `ToolCallBlock` — the generic expandable tool-call card.
/// Focused on the `.awaitingConfirmation` status badge added with the native
/// web-search cost gate: the native-search proposal renders its own
/// `SearchConfirmationRow` and never reaches this card, so the badge is only
/// exercised by a future destructive tool parked for approval — pin it now so
/// that path ships with coverage. Light / dark / sepia per AGENTS.md §Testing.
///
/// `.serialized` for the same TOCTOU reason as the other snapshot suites
/// (parallel writes race on the `__Snapshots__/` PNGs, not on code under test).
@Suite("ToolCallBlock snapshots", .serialized)
@MainActor
struct ToolCallBlockSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    private func awaitingCall() -> MessageList.ToolCallItem {
        MessageList.ToolCallItem(
            id: "tc-1",
            toolName: "home.unlockDoor",
            // No registered descriptor → display name falls back to the
            // technical name (header renders it in the regular caption font).
            toolDisplayName: "home.unlockDoor",
            parametersJSON: #"{"door":"front"}"#,
            resultText: nil,
            status: .awaitingConfirmation
        )
    }

    /// A tool whose friendly `toolDisplayName` differs from its technical
    /// `toolName` — the header shows the friendly name and the expanded body
    /// surfaces the technical name under `FUNCTION` (the
    /// `toolName != toolDisplayName` branch in `ToolCallBlock`). The
    /// `awaiting*` fixtures set the two equal, so they never exercise it.
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

    @Test("awaiting confirmation badge, sepia")
    func awaitingSepia() {
        verify(call: awaitingCall(), theme: .sepiaLight, name: "toolcall_awaiting_sepia")
    }

    // FUNCTION-detail card across the light / dark / sepia × default Dynamic
    // Type matrix (AGENTS.md §3), plus an XXL variant for the extra row's
    // reflow. Taller frame than the awaiting cards: this card adds the
    // FUNCTION row above INPUT.
    @Test("friendly display name surfaces the FUNCTION detail, light")
    func functionDetailLight() {
        verify(call: renamedCall(), theme: .vellumLight, name: "toolcall_function_detail_light", height: 180)
    }

    @Test("friendly display name surfaces the FUNCTION detail, dark")
    func functionDetailDark() {
        verify(call: renamedCall(), theme: .vellumDark, name: "toolcall_function_detail_dark", height: 180)
    }

    @Test("friendly display name surfaces the FUNCTION detail, sepia")
    func functionDetailSepia() {
        verify(call: renamedCall(), theme: .sepiaLight, name: "toolcall_function_detail_sepia", height: 180)
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
        // `.verbose` so the card is expanded and the INPUT panel + badge both
        // render in the frame.
        let view = ToolCallBlock(call: call, verbosity: .verbose)
            .superTheme(.make(theme))
            .dynamicTypeSize(dynamicType)
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
            .frame(width: 402, height: height)

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
