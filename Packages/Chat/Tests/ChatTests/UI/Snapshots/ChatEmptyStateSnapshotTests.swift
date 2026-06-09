#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Snapshots for the empty-state brand glyph in both per-target variants —
/// the default `.spark` (SuperOS) and the `.star` override (SuperBible) —
/// each in Vellum light and dark. The glyph is a fixed-size shape with no
/// text, so there is no Dynamic Type reflow variant.
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

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 600)),
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
