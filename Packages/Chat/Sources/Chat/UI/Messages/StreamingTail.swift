import Core
import Foundation
import SwiftUI

struct StreamingTail: View {
    let tail: MessageList.StreamingState
    let verbosity: ChatVerbosity
    var isActive = true
    var thinkingExpansion: Binding<Bool>?
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.chatAppearance) private var appearance

    // Keep a working cue through token gaps; compaction already has its own indicator.
    private var showsWaitingSpark: Bool {
        isActive && !tail.isCompacting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isActive && tail.isCompacting {
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
                    durationSource: isActive
                        ? .live(startedAt: tail.thinkingStartedAt ?? Date())
                        : .finished(durationMs: tail.thinkingDurationMs),
                    verbosity: verbosity,
                    expansion: thinkingExpansion
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
