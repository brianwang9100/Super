import Core
import SwiftUI

/// The inline cluster of decoration glyphs that trails a verse number.
///
/// Stable order: the annotation bubble first (left), the note glyph second
/// (right), with a tight even gap — so wherever both a note and an
/// annotation exist on the same passage, the two glyph systems always read
/// in the same arrangement (`notes/atoms.jsx` `VerseTrailers`). Pass any
/// subset; an absent glyph collapses without leaving a gap, and an empty
/// cluster renders nothing.
///
/// Presentation only — no tap handling. The glyphs always render `.filled`
/// here because a trailer appears only once its target carries a row. PR3
/// wires the reader's per-glyph tap targets (open the annotation sheet /
/// the note list) when it folds this cluster into `VerseFlowLayout`; until
/// then this is the shape the snapshot guards so the spacing contract is
/// locked before integration.
struct VerseTrailers: View {
    let hasAnnotation: Bool
    let hasNote: Bool
    let size: CGFloat

    init(hasAnnotation: Bool, hasNote: Bool, size: CGFloat = 14) {
        self.hasAnnotation = hasAnnotation
        self.hasNote = hasNote
        self.size = size
    }

    var body: some View {
        if hasAnnotation || hasNote {
            HStack(spacing: 3) {
                if hasAnnotation {
                    AnnotationBubble(state: .filled, size: size)
                }
                if hasNote {
                    NoteGlyph(state: .filled, size: size)
                }
            }
            .padding(.leading, 3)
            .accessibilityHidden(true)
        }
    }
}
