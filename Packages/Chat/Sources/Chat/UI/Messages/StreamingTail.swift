import Foundation
import SwiftUI

/// Live streaming overlay rendered as the trailing row in ``MessageList``
/// while a turn is in flight. Shows a "Compacting…" row, a live thinking
/// block, accumulated text with a typing caret, and a spinning spark
/// while the assistant is still working.
struct StreamingTail: View {
    let tail: MessageList.StreamingState
    let verbosity: ChatVerbosity
    @Environment(\.superTheme) private var theme

    /// The spark spins for the entire duration of the turn so the user
    /// always has a "still working" cue — both before the first delta
    /// (where there's nothing else on screen) and during text streaming
    /// (where the typing caret signals the active line, but the spark
    /// signals the overall turn isn't done yet). Suppressed during
    /// compaction so we don't double up with the "Compacting…" row's
    /// own progress indicator.
    private var showsWaitingSpark: Bool {
        !tail.isCompacting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tail.isCompacting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Compacting…")
                        .font(.system(.caption))
                        .foregroundStyle(theme.inkFaint)
                }
                .padding(.vertical, 6)
            }
            if !tail.thinking.isEmpty {
                ThinkingBlock(
                    text: tail.thinking,
                    durationSource: .live(startedAt: tail.thinkingStartedAt ?? Date()),
                    verbosity: verbosity
                )
            }
            if !tail.text.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(tail.text)
                        .font(.system(.subheadline))
                        .lineSpacing(2)
                        .foregroundStyle(theme.ink)
                    TypingCaret()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showsWaitingSpark {
                WaitingSpark()
            }
        }
        .padding(.vertical, 2)
    }
}
