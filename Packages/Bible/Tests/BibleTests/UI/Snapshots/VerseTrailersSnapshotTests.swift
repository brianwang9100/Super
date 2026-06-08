#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `VerseTrailers` — the inline glyph cluster after a verse
/// number. The co-trailing variant (annotation bubble + note glyph) is the
/// load-bearing case: it locks the stable left-to-right order and the 3pt
/// gap before PR3 folds the cluster into `VerseFlowLayout`. The single
/// variants confirm each glyph collapses without leaving a gap.
@Suite("VerseTrailers snapshots")
@MainActor
struct VerseTrailersSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("annotation + note co-trail in stable order, light")
    func bothLight() {
        verify(theme: .vellumLight, hasAnnotation: true, hasNote: true, name: "both_light")
    }

    @Test("annotation + note co-trail in stable order, dark")
    func bothDark() {
        verify(theme: .vellumDark, hasAnnotation: true, hasNote: true, name: "both_dark")
    }

    @Test("note glyph alone collapses the annotation slot")
    func noteOnlyLight() {
        verify(theme: .vellumLight, hasAnnotation: false, hasNote: true, name: "note_only_light")
    }

    @Test("note glyph alone collapses the annotation slot, dark")
    func noteOnlyDark() {
        verify(theme: .vellumDark, hasAnnotation: false, hasNote: true, name: "note_only_dark")
    }

    @Test("annotation bubble alone collapses the note slot")
    func annotationOnlyLight() {
        verify(theme: .vellumLight, hasAnnotation: true, hasNote: false, name: "annotation_only_light")
    }

    @Test("annotation bubble alone collapses the note slot, dark")
    func annotationOnlyDark() {
        verify(theme: .vellumDark, hasAnnotation: true, hasNote: false, name: "annotation_only_dark")
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        hasAnnotation: Bool,
        hasNote: Bool,
        name: String,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        // A faux verse number anchors the cluster so the baseline shows the
        // trailers in the context they render in — after type, not floating.
        let view = ZStack {
            theme.background
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("16")
                    .font(.system(size: 17, design: .serif))
                    .foregroundStyle(theme.ink)
                VerseTrailers(hasAnnotation: hasAnnotation, hasNote: hasNote, size: 18)
            }
        }
        .frame(width: 160, height: 64)
        .superTheme(theme)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 160, height: 64)),
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
