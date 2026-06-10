#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Snapshot matrix for `ComposerAccessoryFlank` — the leading / trailing
/// hovering glass buttons rendered beside the chat composer pill (today the
/// Bible reader's previous / next chapter chevrons). Covers both-enabled in the
/// default light / dark themes plus the canon-end disabled states (leading
/// dimmed at the start, trailing dimmed at the end). The host's fade-on-expand
/// and vertical placement live in the shell layer, not this view, so they're
/// verified manually in the sim.
@Suite("ComposerAccessoryFlank snapshots")
@MainActor
struct ComposerAccessoryFlankSnapshotTests {
    /// Register Core's bundled brand fonts before any render so this suite is
    /// order-independent in the shared test process (the xctest host never runs
    /// the app's font registration). See SnapshotFontRegistration.
    init() { SnapshotFontRegistration.ensureRegistered() }

    private func chevrons(
        leadingEnabled: Bool = true,
        trailingEnabled: Bool = true
    ) -> ComposerAccessoryButtons {
        ComposerAccessoryButtons(
            leading: ComposerAccessoryButton(
                systemImage: "chevron.left",
                accessibilityLabel: "Previous chapter",
                isEnabled: leadingEnabled,
                action: {}
            ),
            trailing: ComposerAccessoryButton(
                systemImage: "chevron.right",
                accessibilityLabel: "Next chapter",
                isEnabled: trailingEnabled,
                action: {}
            )
        )
    }

    private func host(_ buttons: ComposerAccessoryButtons, theme: SuperTheme.Identifier) -> some View {
        ComposerAccessoryFlank(buttons: buttons)
            .padding(.horizontal, 16)
            .frame(width: 402, height: 60)
            .background(SuperTheme.make(theme).background)
            .superTheme(.make(theme))
            .superTypography(.make(SuperTypography.Identifier.serif))
    }

    private func recordOrCompare<V: View>(view: V, name: String, function: String = #function) {
        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 60)),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure { Issue.record("\(name): \(failure)") }
    }

    @Test("both chevrons enabled — light")
    func bothEnabledLight() {
        recordOrCompare(view: host(chevrons(), theme: .vellumLight), name: "flank_both_enabled_light")
    }

    @Test("both chevrons enabled — dark")
    func bothEnabledDark() {
        recordOrCompare(view: host(chevrons(), theme: .vellumDark), name: "flank_both_enabled_dark")
    }

    @Test("leading chevron disabled at the start of the canon — light")
    func leadingDisabledLight() {
        recordOrCompare(
            view: host(chevrons(leadingEnabled: false), theme: .vellumLight),
            name: "flank_leading_disabled_light"
        )
    }

    @Test("trailing chevron disabled at the end of the canon — light")
    func trailingDisabledLight() {
        recordOrCompare(
            view: host(chevrons(trailingEnabled: false), theme: .vellumLight),
            name: "flank_trailing_disabled_light"
        )
    }

    @Test("leading chevron disabled — dark (dim glyph on dark glass)")
    func leadingDisabledDark() {
        recordOrCompare(
            view: host(chevrons(leadingEnabled: false), theme: .vellumDark),
            name: "flank_leading_disabled_dark"
        )
    }
}
#endif
