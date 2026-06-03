import Core
import SwiftUI

/// One line in the per-book progress list: a status leaf, the chapter
/// reference, and a state-dependent right cell — annotation count (done),
/// "generating" (active), "queued" (waiting), or a Retry pill (failed).
struct BulkChapterRow: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    let bookName: String
    let chapter: BulkChapterProgress
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            BulkStatusLeaf(state: chapter.state, size: 22)

            Text("\(bookName) \(chapter.number)")
                .font(typography.font(.subheadline, weight: chapter.state == .generating ? .semibold : .medium))
                .foregroundStyle(chapter.state == .queued ? theme.inkSoft : theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)

            rightCell
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 4)
        .opacity(chapter.state == .queued ? 0.78 : 1)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.borderFaint).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bookName) \(chapter.number), \(accessibilityStatus)")
    }

    @ViewBuilder
    private var rightCell: some View {
        switch chapter.state {
        case .done:
            HStack(spacing: 5) {
                AnnotationBubble(state: .filled, size: 12)
                Text(chapter.producedCount.formatted())
                    .font(typography.mono(11.5))
                    .foregroundStyle(theme.inkFaint)
            }
        case .generating:
            Text("generating")
                .font(typography.mono(11.5))
                .foregroundStyle(theme.accent)
        case .queued:
            Text("queued")
                .font(typography.mono(11.5))
                .foregroundStyle(theme.inkMute)
        case .failed:
            BulkRetryButton(action: onRetry)
        }
    }

    private var accessibilityStatus: String {
        switch chapter.state {
        case .done: return "\(chapter.producedCount) annotations"
        case .generating: return "generating"
        case .queued: return "queued"
        case .failed: return "failed"
        }
    }
}
