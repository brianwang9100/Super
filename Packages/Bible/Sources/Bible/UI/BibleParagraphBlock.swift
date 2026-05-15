import Core
import SwiftUI

/// Renders one `BibleParagraph`: a section heading, a prose paragraph, or a
/// poetry stanza. Prose and poetry concatenate their verses into a single
/// wrapping `Text`; poetry is italic, indented, and keeps the `\n` line
/// breaks carried in its verse text.
struct BibleParagraphBlock: View {
    let paragraph: BibleParagraph
    @Environment(\.superTheme) private var theme

    var body: some View {
        switch paragraph {
        case .heading(let title):
            Text(title)
                .font(.system(.title2, design: .serif))
                .fontWeight(.semibold)
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 20)
                .padding(.bottom, 2)
        case .prose(let verses):
            joined(verses)
                .font(.body)
                .foregroundStyle(theme.ink)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .poetry(let verses):
            joined(verses)
                .font(.body.italic())
                .foregroundStyle(theme.ink)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 20)
        }
    }

    private func joined(_ verses: [BibleVerse]) -> Text {
        verses.reduce(Text("")) { running, verse in
            running + BibleVerseSpan(verse: verse).text(theme: theme)
        }
    }
}
