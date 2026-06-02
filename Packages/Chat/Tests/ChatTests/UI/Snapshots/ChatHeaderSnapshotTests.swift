#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Pixel-stable snapshots of `ChatHeader` across all three themes. The
/// view is wrapped in a fixed-width container so the layout doesn't
/// depend on the host device's safe-area insets.
@Suite("ChatHeader snapshots", .serialized)
@MainActor
struct ChatHeaderSnapshotTests {
    /// Register Core's bundled brand fonts before any render so this suite
    /// is order-independent in the shared test process (the xctest host never
    /// runs the app's font registration). See SnapshotFontRegistration.
    init() { SnapshotFontRegistration.ensureRegistered() }
    @Test("light theme")
    func lightTheme() {
        verify(theme: .light, name: "header_light")
    }

    @Test("dark theme")
    func darkTheme() {
        verify(theme: .dark, name: "header_dark")
    }

    @Test("sepia theme")
    func sepiaTheme() {
        verify(theme: .sepia, name: "header_sepia")
    }

    @Test("very long title truncates")
    func longTitleTruncates() {
        let long = "An overly long conversation title that should ellipsis"
        let view = ChatHeader(title: long)
            .superTheme(.make(.light))
            .frame(width: 402)
        recordOrCompare(view: view, name: "header_long_title")
    }

    @Test("dynamic type XXL light")
    func dynamicTypeXXL() {
        let view = ChatHeader(title: "New chat")
            .superTheme(.make(.light))
            .dynamicTypeSize(.xxLarge)
            .frame(width: 402)
        recordOrCompare(view: view, name: "header_light_xxl")
    }

    /// Locks the `* appearance.fontScale` wiring on the title font. At the
    /// default `fontScale == 1.0` the multiplication is a no-op, so the
    /// remaining baselines would stay green if the multiplication were
    /// deleted. Injecting the upper-bound knob proves the title actually
    /// tracks the slider, mirroring `MessageListSnapshotTests`'
    /// `appearanceScaleMax` precedent.
    @Test("font scale max light")
    func fontScaleMax() {
        let view = ChatHeader(title: "New chat")
            .superTheme(.make(.light))
            .chatAppearance(ChatAppearance(fontScale: 1.20))
            .superTypography(.make(.serif, fontScale: 1.20))
            .frame(width: 402)
        recordOrCompare(view: view, name: "header_font_scale_max_light")
    }

    /// Dark-mode counterpart to ``fontScaleMax`` — per AGENTS.md §Testing.3
    /// every new SwiftUI variant needs a light + dark pair. Catches
    /// regressions where the larger title size interacts with the dark
    /// palette (border, blur tint, ink) in ways the light baseline misses.
    @Test("font scale max dark")
    func fontScaleMaxDark() {
        let view = ChatHeader(title: "New chat")
            .superTheme(.make(.dark))
            .chatAppearance(ChatAppearance(fontScale: 1.20))
            .superTypography(.make(.serif, fontScale: 1.20))
            .frame(width: 402)
        recordOrCompare(view: view, name: "header_font_scale_max_dark")
    }

    /// Sepia counterpart to ``fontScaleMax`` — Chat AGENTS.md's snapshot
    /// matrix is `light/dark/sepia × default/Dynamic Type XXL` and every
    /// other ChatHeader baseline covers the warm sepia palette. Catches
    /// regressions where the scaled title interacts with sepia's ink and
    /// background-blur tint specifically.
    @Test("font scale max sepia")
    func fontScaleMaxSepia() {
        let view = ChatHeader(title: "New chat")
            .superTheme(.make(.sepia))
            .chatAppearance(ChatAppearance(fontScale: 1.20))
            .superTypography(.make(.serif, fontScale: 1.20))
            .frame(width: 402)
        recordOrCompare(view: view, name: "header_font_scale_max_sepia")
    }

    /// The extreme upper-bound: maxed font slider stacked on top of XXL
    /// Dynamic Type. `@ScaledMetric(relativeTo: .subheadline)` already
    /// scales `titleBase` from 17 → ~20pt at XXL; the further `× 1.20`
    /// from the slider pushes the rendered title to ~24pt, the largest
    /// the user can reach. Locks the corner case where the title might
    /// vertically push the header taller than the menu-button row and
    /// shift the centered-layout balance.
    @Test("font scale max at dynamic type XXL")
    func fontScaleMaxXXL() {
        let view = ChatHeader(title: "New chat")
            .superTheme(.make(.light))
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
        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .sizeThatFits),
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
