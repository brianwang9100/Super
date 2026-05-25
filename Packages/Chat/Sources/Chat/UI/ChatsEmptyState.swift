import Core
import SwiftUI

/// Centered placeholder shown by `ChatsScreen` when the list is empty.
/// Two cases — the database has no conversations at all (`.noChats`),
/// or a search filter excluded every row (`.noMatches`). The screen
/// picks `.noChats` over `.noMatches` when the database is empty so a
/// stray query doesn't suppress the more useful first-run guidance.
struct ChatsEmptyState: View {
    /// Which empty state to render.
    enum Mode: Equatable {
        /// Zero conversations on disk — invite the user to start one.
        case noChats
        /// Database is non-empty but the active search returned zero
        /// rows. The associated string is the trimmed query, rendered
        /// quoted inside the caption so the user sees what they typed.
        case noMatches(query: String)
    }

    let mode: Mode

    @ScaledMetric(relativeTo: .title2) private var headlineSize: CGFloat = 22
    @ScaledMetric(relativeTo: .footnote) private var captionSize: CGFloat = 13
    @Environment(\.superFontScale) private var fontScale
    @Environment(\.superTheme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            Text(headline)
                .font(.system(size: headlineSize * fontScale, design: .serif).italic())
                .foregroundStyle(theme.inkSoft)
                .multilineTextAlignment(.center)
            caption
                .font(.system(size: captionSize * fontScale))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
    }

    private var headline: String {
        switch mode {
        case .noChats: return "No chats"
        case .noMatches: return "No matches."
        }
    }

    @ViewBuilder private var caption: some View {
        switch mode {
        case .noChats:
            Text("Tap + button to start new chat")
                .foregroundStyle(theme.inkFaint)
        case .noMatches(let query):
            // Built as a composed `Text` so the quoted query reads in
            // `theme.ink` against the surrounding `theme.inkFaint`
            // prose — matches the original search-empty styling.
            Text("Nothing in your history matches ")
                .foregroundStyle(theme.inkFaint)
            + Text("\u{201C}\(query)\u{201D}")
                .foregroundStyle(theme.ink)
            + Text(".")
                .foregroundStyle(theme.inkFaint)
        }
    }
}
