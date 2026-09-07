#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

// Serial execution guards recording writes to the shared snapshot directory.
/// Snapshot matrix for `ComposerAccessoryFlank` — the leading / trailing
/// hovering glass buttons rendered beside the chat composer pill (today the
/// Bible reader's previous / next chapter chevrons). Covers both-enabled in the
/// default light / dark themes plus the canon-end disabled states (leading
/// dimmed at the start, trailing dimmed at the end), plus persistent disclosure
/// selection controls, independently hidden edges, long labels, and larger text.
/// Reduce Motion changes only transitions, so settled pixels are identical;
/// its read-only environment value is exercised manually in the simulator.
/// The host's fade-on-expand
/// and vertical placement live in the shell layer, not this view, so they're
/// verified manually in the sim.
@Suite("ComposerAccessoryFlank snapshots", .serialized)
@MainActor
struct ComposerAccessoryFlankSnapshotTests {
    /// Register Core's bundled brand fonts before any render so this suite is
    /// order-independent in the shared test process (the xctest host never runs
    /// the app's font registration). See SnapshotFontRegistration.
    init() { SnapshotFontRegistration.ensureRegistered() }

    private func chevrons(
        leadingEnabled: Bool = true,
        trailingEnabled: Bool = true,
        selection: ComposerAccessorySelection? = nil,
        hideButtons: Bool = false
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
            ),
            selection: selection,
            shouldHideButtons: { hideButtons }
        )
    }

    private func host(
        _ buttons: ComposerAccessoryButtons,
        theme: SuperTheme.Identifier,
        fontScale: CGFloat = 1
    ) -> some View {
        ComposerAccessoryFlank(buttons: buttons)
            .padding(.horizontal, 16)
            .frame(width: 402, height: 60)
            .background(SuperTheme.make(theme).background)
            .superTheme(.make(theme))
            .superTypography(.make(.serif, fontScale: fontScale))
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

    @Test("trailing chevron disabled — dark (dim glyph on dark glass)")
    func trailingDisabledDark() {
        recordOrCompare(
            view: host(chevrons(trailingEnabled: false), theme: .vellumDark),
            name: "flank_trailing_disabled_dark"
        )
    }

    @Test("selection always shows the upward disclosure between chapter controls",
          arguments: [SuperTheme.Identifier.vellumLight, .vellumDark])
    func selection(theme: SuperTheme.Identifier) {
        verifySelection(theme: theme, name: "selection_\(theme.rawValue)")
    }

    @Test("footer hides the floating arrows independently of the selection",
          arguments: [SuperTheme.Identifier.vellumLight, .vellumDark])
    func selectionWithoutArrows(theme: SuperTheme.Identifier) {
        verifySelection(
            theme: theme,
            name: "selection_hidden_edges_\(theme.rawValue)",
            hideButtons: true
        )
    }

    @Test("selection keeps both chapter controls at XXL",
          arguments: [SuperTheme.Identifier.vellumLight, .vellumDark])
    func selectionXXL(theme: SuperTheme.Identifier) {
        // These chrome fonts track the app slider, not Dynamic Type. XXL
        // guards layout stability; longSelection exercises the enlarged text.
        verifySelection(theme: theme,
                        name: "selection_\(theme.rawValue)_xxl", dynamicType: .xxLarge)
    }

    @Test("long selections leave room for the chapter arrows and clear control",
          arguments: [SuperTheme.Identifier.vellumLight, .vellumDark])
    func longSelection(theme: SuperTheme.Identifier) {
        verifySelection(theme: theme,
                        name: "selection_\(theme.rawValue)_long", fontScale: 1.2,
                        title: "2 Thessalonians 3:1-3, 5, 7, 9-12, 15, 17")
    }

    private func verifySelection(
        theme: SuperTheme.Identifier,
        name: String,
        dynamicType: DynamicTypeSize = .large,
        fontScale: CGFloat = 1,
        title: String = "1 Peter 2:4-6, 9",
        hideButtons: Bool = false,
        function: String = #function
    ) {
        let selection = ComposerAccessorySelection(
            title: title,
            accessibilityLabel: "\(title), show verse actions",
            onExpand: {},
            onClear: {}
        )
        recordOrCompare(
            view: host(chevrons(selection: selection, hideButtons: hideButtons), theme: theme, fontScale: fontScale)
                .dynamicTypeSize(dynamicType),
            name: name, function: function
        )
    }
}
#endif
