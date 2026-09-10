#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Chat

@Suite("ChatEmptyState snapshots", .serialized)
@MainActor
struct ChatEmptyStateSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("spark glyph in light")
    func sparkLight() {
        verify(glyph: .spark, theme: .vellumLight, name: "empty_spark_light")
    }

    @Test("spark glyph in dark")
    func sparkDark() {
        verify(glyph: .spark, theme: .vellumDark, name: "empty_spark_dark")
    }

    @Test("star glyph in light")
    func starLight() {
        verify(glyph: .star, theme: .vellumLight, name: "empty_star_light")
    }

    @Test("star glyph in dark")
    func starDark() {
        verify(glyph: .star, theme: .vellumDark, name: "empty_star_dark")
    }

    private func verify(
        glyph: ChatEmptyStateGlyph,
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let view = ChatEmptyState()
            .chatEmptyStateGlyph(glyph)
            .superTheme(.make(theme))
            .frame(width: 402, height: 600)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 600)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
