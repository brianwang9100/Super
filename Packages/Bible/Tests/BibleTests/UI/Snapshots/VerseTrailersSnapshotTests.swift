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
    @Test("annotation + note co-trail in stable order, light")
    func bothLight() {
        verify(theme: .light, hasAnnotation: true, hasNote: true, name: "both_light")
    }

    @Test("annotation + note co-trail in stable order, dark")
    func bothDark() {
        verify(theme: .dark, hasAnnotation: true, hasNote: true, name: "both_dark")
    }

    @Test("annotation + note co-trail in stable order, sepia")
    func bothSepia() {
        verify(theme: .sepia, hasAnnotation: true, hasNote: true, name: "both_sepia")
    }

    @Test("note glyph alone collapses the annotation slot")
    func noteOnlyLight() {
        verify(theme: .light, hasAnnotation: false, hasNote: true, name: "note_only_light")
    }

    @Test("note glyph alone collapses the annotation slot, dark")
    func noteOnlyDark() {
        verify(theme: .dark, hasAnnotation: false, hasNote: true, name: "note_only_dark")
    }

    @Test("note glyph alone collapses the annotation slot, sepia")
    func noteOnlySepia() {
        verify(theme: .sepia, hasAnnotation: false, hasNote: true, name: "note_only_sepia")
    }

    @Test("annotation bubble alone collapses the note slot")
    func annotationOnlyLight() {
        verify(theme: .light, hasAnnotation: true, hasNote: false, name: "annotation_only_light")
    }

    @Test("annotation bubble alone collapses the note slot, dark")
    func annotationOnlyDark() {
        verify(theme: .dark, hasAnnotation: true, hasNote: false, name: "annotation_only_dark")
    }

    @Test("annotation bubble alone collapses the note slot, sepia")
    func annotationOnlySepia() {
        verify(theme: .sepia, hasAnnotation: true, hasNote: false, name: "annotation_only_sepia")
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
