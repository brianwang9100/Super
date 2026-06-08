#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Snapshots for `ErrorBanner`'s detail-disclosure states: collapsed (the
/// "Details" affordance visible) and expanded (the full provider body shown
/// inline). The expanded state is driven by the `initiallyExpanded` test seam,
/// since it's otherwise reachable only by tapping. The plain summary-only
/// banner (no `detail`) is already covered by `MessageListSnapshotTests`.
// `.serialized` for the same shared-`__Snapshots__/`-directory reason as the
// other snapshot suites in this folder.
@Suite("ErrorBanner snapshots", .serialized)
@MainActor
struct ErrorBannerSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    /// A provider error with a multi-line body — the shape Gemini returns on a
    /// 400, and the case the expandable detail exists for.
    private var errorState: MessageList.ErrorState {
        MessageList.ErrorState(
            message: "The model provider returned an error (HTTP 400).",
            detail: """
            {
              "error": {
                "code": 400,
                "message": "Function call is missing a thought_signature in functionCall parts.",
                "status": "INVALID_ARGUMENT"
              }
            }
            """
        )
    }

    @Test("collapsed (Details affordance) — light")
    func collapsedLight() { verify(expanded: false, theme: .vellumLight, height: 140, name: "error_banner_collapsed_light") }

    @Test("collapsed (Details affordance) — dark")
    func collapsedDark() { verify(expanded: false, theme: .vellumDark, height: 140, name: "error_banner_collapsed_dark") }

    @Test("expanded detail — light")
    func expandedLight() { verify(expanded: true, theme: .vellumLight, height: 360, name: "error_banner_expanded_light") }

    @Test("expanded detail — dark")
    func expandedDark() { verify(expanded: true, theme: .vellumDark, height: 360, name: "error_banner_expanded_dark") }

    @Test("collapsed at Dynamic Type XXL — light")
    func collapsedXXL() {
        verify(expanded: false, theme: .vellumLight, dynamicType: .xxLarge, height: 200, name: "error_banner_collapsed_light_xxl")
    }

    @Test("expanded detail at Dynamic Type XXL — light (detail text reflows)")
    func expandedXXL() {
        verify(expanded: true, theme: .vellumLight, dynamicType: .xxLarge, height: 520, name: "error_banner_expanded_light_xxl")
    }

    private func verify(
        expanded: Bool,
        theme: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        height: CGFloat,
        name: String,
        function: String = #function
    ) {
        let view = ErrorBanner(banner: errorState, initiallyExpanded: expanded, onRetry: {})
            .superTheme(.make(theme))
            .dynamicTypeSize(dynamicType)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
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
