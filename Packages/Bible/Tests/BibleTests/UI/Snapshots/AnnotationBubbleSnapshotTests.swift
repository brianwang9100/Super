#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Bible

/// Filled states cover theme colors; light captures suffice for the stroke-only state differences.
@Suite("AnnotationBubble snapshots", .serialized)
@MainActor
struct AnnotationBubbleSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("filled bubble renders in the light theme")
    func filledLight() {
        verify(theme: .vellumLight, state: .filled, name: "filled_light")
    }

    @Test("filled bubble renders in the dark theme")
    func filledDark() {
        verify(theme: .vellumDark, state: .filled, name: "filled_dark")
    }

    @Test("empty bubble renders in the light theme")
    func emptyLight() {
        verify(theme: .vellumLight, state: .empty, name: "empty_light")
    }

    @Test("generating bubble renders in the light theme")
    func generatingLight() {
        verify(theme: .vellumLight, state: .generating, name: "generating_light")
    }

    /// Overlapping ranges ending on one verse must keep separate, evenly spaced bubbles.
    @Test("three bubbles stack horizontally after one verse")
    func multiStackLight() {
        let theme = SuperTheme.make(.vellumLight)
        let view = ZStack {
            theme.background
            HStack(spacing: 3) {
                AnnotationBubble(state: .filled, size: 24)
                AnnotationBubble(state: .filled, size: 24)
                AnnotationBubble(state: .filled, size: 24)
            }
        }
        .frame(width: 144, height: 64)
        .superTheme(theme)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 144, height: 64)),
            named: "multi_stack_light",
            testName: #function
        )
        if let failure {
            Issue.record("multi_stack_light: \(failure)")
        }
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        state: AnnotationBubble.BubbleState,
        name: String,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        // Enlarge the glyph to make edge antialiasing and the tail inspectable.
        let view = ZStack {
            theme.background
            AnnotationBubble(state: state, size: 48)
        }
        .frame(width: 96, height: 96)
        .superTheme(theme)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 96, height: 96)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
