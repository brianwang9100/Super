import Core
import SwiftUI

/// The Bible reading surface. Renders one already-loaded chapter as a
/// scrolling column of heading, prose, and poetry paragraphs.
///
/// M1 renders a fixed chapter (1 Peter 2). The navigation bar, chapter
/// stepping, and reading-position persistence land in later milestones; for
/// now the chapter is supplied by `BibleApplet` at composition time so this
/// view stays pure and synchronously snapshot-testable.
public struct BibleScreen: View {
    @Environment(\.superTheme) private var theme
    private let bookName: String
    private let chapter: BibleChapter?

    /// - Parameters:
    ///   - bookName: display name shown in the chapter title.
    ///   - chapter: the chapter to render, or `nil` when the book text
    ///     failed to load — the screen then shows an unavailable state.
    public init(bookName: String, chapter: BibleChapter?) {
        self.bookName = bookName
        self.chapter = chapter
    }

    public var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            if let chapter, !chapter.paragraphs.isEmpty {
                reader(chapter)
            } else {
                unavailable
            }
        }
    }

    private func reader(_ chapter: BibleChapter) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(bookName) \(chapter.number)")
                    .font(.system(.largeTitle, design: .serif))
                    .italic()
                    .foregroundStyle(theme.ink)
                    .padding(.bottom, 6)
                ForEach(Array(chapter.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    BibleParagraphBlock(paragraph: paragraph)
                }
                // Bottom inset so the chat overlay's minimized pill doesn't
                // obscure the last verses — mirrors the shell's 76pt reserve.
                Color.clear.frame(height: 76)
            }
            .padding(.horizontal, 26)
            .padding(.top, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var unavailable: some View {
        VStack(spacing: 10) {
            BibleAppletIcon(size: 40)
                .foregroundStyle(theme.inkFaint)
            Text("Chapter unavailable")
                .font(.system(.headline, design: .serif))
                .foregroundStyle(theme.inkSoft)
        }
        .padding(28)
    }
}

#Preview {
    BibleScreen(
        bookName: "1 Peter",
        chapter: BibleChapter(number: 2, paragraphs: [
            .heading("A Living Stone and a Holy People"),
            .prose([
                BibleVerse(number: 1, text: "Putting away therefore all wickedness, all deceit, hypocrisies, envies, and all evil speaking,"),
                BibleVerse(number: 2, text: "as newborn babies, long for the pure spiritual milk, that with it you may grow,"),
            ]),
            .poetry([
                BibleVerse(number: 6, text: "“Behold, I lay in Zion a chief cornerstone, chosen and precious.\nHe who believes in him will not be disappointed.”"),
            ]),
        ])
    )
    .superTheme(.make(.light))
}
