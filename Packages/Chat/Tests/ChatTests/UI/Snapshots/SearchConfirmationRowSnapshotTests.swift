#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Snapshots for `SearchConfirmationRow` — the native web-search cost-gate
/// prompt rendered under an assistant turn. The awaiting state pins the
/// query/reason card + Search/Skip buttons across light / dark / sepia and a
/// Dynamic Type XXL reflow case; the resolved states pin the compact
/// "searched" / "skipped" summaries the row collapses to after a decision,
/// each across light / dark / sepia plus an XXL reflow variant.
///
/// `.serialized` for the same TOCTOU reason as the other snapshot suites
/// (parallel writes race on the `__Snapshots__/` PNGs, not on code under
/// test). Reduce Motion is not a separate variant: the row swaps subviews on
/// a plain status change with no `withAnimation`, so steady-state frames are
/// identical regardless of `accessibilityReduceMotion`.
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
        verify(status: .awaitingConfirmation, theme: .light, height: 200, name: "search_confirm_awaiting_light")
    }

    @Test("awaiting, dark")
    func awaitingDark() {
        verify(status: .awaitingConfirmation, theme: .dark, height: 200, name: "search_confirm_awaiting_dark")
    }

    @Test("awaiting, sepia")
    func awaitingSepia() {
        verify(status: .awaitingConfirmation, theme: .sepia, height: 200, name: "search_confirm_awaiting_sepia")
    }

    @Test("awaiting, dynamic type XXL")
    func awaitingXXL() {
        verify(
            status: .awaitingConfirmation, theme: .light, dynamicType: .xxLarge, height: 320,
            name: "search_confirm_awaiting_light_xxl"
        )
    }

    @Test("resolved searched, light")
    func searchedLight() {
        verify(status: .success, theme: .light, height: 80, name: "search_confirm_searched_light")
    }

    @Test("resolved searched, dark")
    func searchedDark() {
        verify(status: .success, theme: .dark, height: 80, name: "search_confirm_searched_dark")
    }

    @Test("resolved searched, sepia")
    func searchedSepia() {
        verify(status: .success, theme: .sepia, height: 80, name: "search_confirm_searched_sepia")
    }

    @Test("resolved skipped, light")
    func skippedLight() {
        verify(status: .failed, theme: .light, height: 80, name: "search_confirm_skipped_light")
    }

    @Test("resolved skipped, dark")
    func skippedDark() {
        verify(status: .failed, theme: .dark, height: 80, name: "search_confirm_skipped_dark")
    }

    @Test("resolved skipped, sepia")
    func skippedSepia() {
        verify(status: .failed, theme: .sepia, height: 80, name: "search_confirm_skipped_sepia")
    }

    // The resolved summaries are single-line in the steady case, but the
    // "searched" summary embeds an arbitrary model-generated query that can
    // wrap at XXL. Pin both resolved states at XXL so a long query's reflow
    // is captured rather than silently regressing.
    @Test("resolved searched, dynamic type XXL")
    func searchedXXL() {
        verify(
            status: .success, theme: .light, dynamicType: .xxLarge, height: 140,
            name: "search_confirm_searched_light_xxl"
        )
    }

    @Test("resolved skipped, dynamic type XXL")
    func skippedXXL() {
        verify(
            status: .failed, theme: .light, dynamicType: .xxLarge, height: 140,
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
