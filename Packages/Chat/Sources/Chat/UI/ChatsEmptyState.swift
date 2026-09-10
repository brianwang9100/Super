import Core
import SwiftUI

struct ChatsEmptyState: View {
    enum Mode: Equatable {
        case noChats
        case noMatches(query: String)
    }

    let mode: Mode

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    /// System faces need ScaledMetric for Dynamic Type; brand display fonts use relativeTo.
    @ScaledMetric(relativeTo: .footnote) private var captionSize: CGFloat = 13

    var body: some View {
        VStack(spacing: 6) {
            Text(headline)
                .font(typography.display(22, relativeTo: .title2))
                // Supply the slant absent from the system display face.
                .italic()
                .foregroundStyle(theme.inkSoft)
                .multilineTextAlignment(.center)
            caption
                .font(typography.font(size: captionSize))
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
            Text(noMatchesCaption(query: query))
        }
    }

    private func noMatchesCaption(query: String) -> AttributedString {
        var prose = AttributedString("Nothing in your history matches ")
        prose.foregroundColor = theme.inkFaint
        var quoted = AttributedString("\u{201C}\(query)\u{201D}")
        quoted.foregroundColor = theme.ink
        var period = AttributedString(".")
        period.foregroundColor = theme.inkFaint
        return prose + quoted + period
    }
}
