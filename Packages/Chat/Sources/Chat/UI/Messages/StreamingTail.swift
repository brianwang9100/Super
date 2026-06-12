import Core
import Foundation
import SwiftUI

/// Live streaming overlay rendered as the trailing row in ``MessageList``
/// while a turn is in flight. Shows a "Compacting…" row, a live thinking
/// block, the in-flight text as progressive markdown (via
/// ``MarkdownText`` in partial-input mode), and a spinning spark while
/// the assistant is still working.
struct StreamingTail: View {
    let tail: MessageList.StreamingState
    let verbosity: ChatVerbosity
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.chatAppearance) private var appearance

    /// The spark spins for the entire duration of the turn so the user
    /// always has a "still working" cue — both before the first delta
    /// (where there's nothing else on screen) and during text streaming
    /// (where the markdown body alone wouldn't signal the overall turn
    /// isn't done yet). Suppressed during compaction so we don't double
    /// up with the "Compacting…" row's own progress indicator.
    private var showsWaitingSpark: Bool {
        !tail.isCompacting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tail.isCompacting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Compacting…")
                        .font(typography.font(.caption))
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
                MarkdownText(tail.text, treatAsPartial: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsWaitingSpark {
                WaitingSpark()
            }
        }
        .padding(.vertical, appearance.assistantRowVerticalPadding)
    }
}
