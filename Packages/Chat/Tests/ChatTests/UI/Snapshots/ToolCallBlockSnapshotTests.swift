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
            parametersJSON: #"{"door":"front"}"#,
            resultText: nil,
            status: .awaitingConfirmation
        )
    }

    @Test("awaiting confirmation badge, light")
    func awaitingLight() {
        verify(theme: .light, name: "toolcall_awaiting_light")
    }

    @Test("awaiting confirmation badge, dark")
    func awaitingDark() {
        verify(theme: .dark, name: "toolcall_awaiting_dark")
    }

    @Test("awaiting confirmation badge, sepia")
    func awaitingSepia() {
        verify(theme: .sepia, name: "toolcall_awaiting_sepia")
    }

    private func verify(theme: SuperTheme.Identifier, name: String, function: String = #function) {
        // `.verbose` so the card is expanded and the INPUT panel + badge both
        // render in the frame.
        let view = ToolCallBlock(call: awaitingCall(), verbosity: .verbose)
            .superTheme(.make(theme))
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
            .frame(width: 402, height: 140)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 140)),
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
