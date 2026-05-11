import SwiftUI

/// Divider strip rendered between the pre-compaction history and the new
/// summary the model wrote. Shows a "COMPACTED" rule and a 3-line
/// markdown rendering of the summary.
struct CompactionBanner: View {
    let summary: String
    @Environment(\.superTheme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                line
                Text("COMPACTED")
                    .font(.system(.caption2).weight(.medium))
                    .tracking(0.6)
                    .foregroundStyle(theme.inkFaint)
                line
            }
            MarkdownText(summary, bodyStyleOverride: .banner)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.backgroundSunken)
                )
        }
        .padding(.vertical, 8)
    }

    private var line: some View {
        Rectangle()
            .fill(theme.borderFaint)
            .frame(height: 1)
    }
}
