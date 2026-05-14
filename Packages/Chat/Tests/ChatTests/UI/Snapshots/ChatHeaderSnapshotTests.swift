#if canImport(UIKit)
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
        let view = ChatHeader(title: long, onMenuTap: {})
            .superTheme(.make(.light))
            .frame(width: 402)
        recordOrCompare(view: view, name: "header_long_title")
    }

    @Test("dynamic type XXL light")
    func dynamicTypeXXL() {
        let view = ChatHeader(title: "New chat", onMenuTap: {})
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
        let view = ChatHeader(title: "New chat", onMenuTap: {})
            .superTheme(.make(.light))
            .chatAppearance(ChatAppearance(fontScale: 1.20))
            .frame(width: 402)
        recordOrCompare(view: view, name: "header_font_scale_max_light")
    }

    /// Dark-mode counterpart to ``fontScaleMax`` — per AGENTS.md §Testing.3
    /// every new SwiftUI variant needs a light + dark pair. Catches
    /// regressions where the larger title size interacts with the dark
    /// palette (border, blur tint, ink) in ways the light baseline misses.
    @Test("font scale max dark")
    func fontScaleMaxDark() {
        let view = ChatHeader(title: "New chat", onMenuTap: {})
            .superTheme(.make(.dark))
            .chatAppearance(ChatAppearance(fontScale: 1.20))
            .frame(width: 402)
        recordOrCompare(view: view, name: "header_font_scale_max_dark")
    }

    private func verify(
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let view = ChatHeader(title: "New chat", onMenuTap: {})
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
