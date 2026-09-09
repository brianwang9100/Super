import Core
import SwiftUI

/// Annotation then note, with no spacing reserved for absent glyphs. Presentation only;
/// the reader owns interactive tap targets.
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
