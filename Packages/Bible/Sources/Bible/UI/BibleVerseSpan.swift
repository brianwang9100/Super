import Core
import SwiftUI

/// Builds the `Text` for one verse fragment — the raised verse number
/// followed by the verse body — which `BibleParagraphBlock` concatenates into
/// a single wrapping paragraph.
struct BibleVerseSpan {
    let verse: BibleVerse

    func text(theme: SuperTheme) -> Text {
        BibleVerseNumber(number: verse.number).text(color: theme.inkFaint)
            + Text(" ")
            + Text(verse.text)
            + Text(" ")
    }
}
